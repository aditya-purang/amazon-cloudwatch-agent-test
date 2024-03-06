// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

//go:build !windows

package metric_value_benchmark

import (
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"math/rand"
	"sort"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/cloudwatch/types"

	"github.com/aws/amazon-cloudwatch-agent-test/environment"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric_value_benchmark/eks_resources"
	"github.com/aws/amazon-cloudwatch-agent-test/test/status"
	"github.com/aws/amazon-cloudwatch-agent-test/test/test_runner"
	"github.com/aws/amazon-cloudwatch-agent-test/util/awsservice"
)

const containerInsightsNamespace = "ContainerInsights"
const gpuMetricIndicator = "_gpu_"

type EKSDaemonTestRunner struct {
	test_runner.BaseTestRunner
	testName string
	env      *environment.MetaData
}

func (e *EKSDaemonTestRunner) Validate() status.TestGroupResult {
	var testResults []status.TestResult
	testResults = append(testResults, validateMetrics(e.env, gpuMetricIndicator, eks_resources.GetExpectedDimsToMetrics(e.env))...)
	testResults = append(testResults, e.validateLogs(e.env))
	return status.TestGroupResult{
		Name:        e.GetTestName(),
		TestResults: testResults,
	}
}

const (
	dimDelimiter               = "-"
	ContainerInsightsNamespace = "ContainerInsights"
)

type dimToMetrics struct {
	// dim keys as string with dimDelimiter(-) eg. ClusterName-Namespace
	dimStr string
	// metric names to their dimensions with values. Dimension sets will be used for metric data validations
	metrics map[string][][]types.Dimension
}

func validateMetrics(env *environment.MetaData, metricFilter string, expectedDimsToMetrics map[string][]string) []status.TestResult {
	var results []status.TestResult
	dimsToMetrics := getMetricsInClusterDimension(env, metricFilter)
	//loops through each dimension set and checks if they exit in the cluster(fails if it doesn't)
	for dims, metrics := range expectedDimsToMetrics {
		var actual map[string][][]types.Dimension
		//looping through dtms until we find the dimension string equal to the one in the hard coded map
		for _, dtm := range dimsToMetrics {
			log.Printf("dtm: %s vs dims %s", dtm.dimStr, dims) //testing purposes
			if dtm.dimStr == dims {
				actual = dtm.metrics
				break
			}
		}
		//if there are no metrics for the dimension set, we fail the test
		if len(actual) < 1 {
			results = append(results, status.TestResult{
				Name:   dims,
				Status: status.FAILED,
			})
			log.Printf("ValidateMetrics failed with missing dimension set: %s", dims)
			// keep testing other dims or fail early?
			continue
		}
		//verifies length of metrics for dimension set
		results = append(results, validateMetricsAvailability(dims, metrics, actual))
		for _, m := range metrics {
			// picking a random dimension set to test metric data so we don't have to test every dimension set
			randIdx := rand.Intn(len(actual[m]))
			//verifys values of metrics
			results = append(results, validateMetricValue(m, actual[m][randIdx]))
		}
	}
	return results
}

// Fetches all metrics in cluster
func getMetricsInClusterDimension(env *environment.MetaData, metricFilter string) []dimToMetrics { //map[string]map[string]interface{} {
	listFetcher := metric.MetricListFetcher{}
	log.Printf("Fetching by cluster dimension")
	dims := []types.Dimension{
		{
			Name:  aws.String("ClusterName"),
			Value: aws.String(env.EKSClusterName),
		},
	}
	metrics, err := listFetcher.Fetch(ContainerInsightsNamespace, "", dims)
	if err != nil {
		log.Println("failed to fetch metric list", err)
		return nil
	}
	if len(metrics) < 1 {
		log.Println("cloudwatch metric list is empty")
		return nil
	}

	var results []dimToMetrics
	for _, m := range metrics {
		// filter by metric name filter(skip gpu validation)
		if metricFilter != "" && strings.Contains(*m.MetricName, metricFilter) {
			continue
		}
		var dims []string
		for _, d := range m.Dimensions {
			dims = append(dims, *d.Name)
		}
		sort.Sort(sort.StringSlice(dims)) //what's the point of sorting?
		dimsKey := strings.Join(dims, dimDelimiter)
		log.Printf("processing dims: %s", dimsKey)

		var dtm dimToMetrics
		for _, ele := range results {
			if ele.dimStr == dimsKey {
				dtm = ele
				break
			}
		}
		if dtm.dimStr == "" {
			dtm = dimToMetrics{
				dimStr:  dimsKey,
				metrics: make(map[string][][]types.Dimension),
			}
			results = append(results, dtm)
		}
		dtm.metrics[*m.MetricName] = append(dtm.metrics[*m.MetricName], m.Dimensions)
	}
	return results
}

// Check if all metrics from cluster matches hard coded map
func validateMetricsAvailability(dims string, expected []string, actual map[string][][]types.Dimension) status.TestResult {
	testResult := status.TestResult{
		Name:   dims,
		Status: status.FAILED,
	}
	log.Printf("expected metrics: %d, actual metrics: %d", len(expected), len(actual))
	if compareMetrics(expected, actual) {
		testResult.Status = status.SUCCESSFUL
	} else {
		log.Printf("validateMetricsAvailability failed for %s", dims)
	}
	return testResult
}

func compareMetrics(expected []string, actual map[string][][]types.Dimension) bool {
	if len(expected) != len(actual) {
		return false
	}

	for _, key := range expected {
		if _, ok := actual[key]; !ok {
			return false
		}
	}
	return true
}

func validateMetricValue(name string, dims []types.Dimension) status.TestResult {
	log.Printf("validateMetricValue with metric: %s", name)
	testResult := status.TestResult{
		Name:   name,
		Status: status.FAILED,
	}
	valueFetcher := metric.MetricValueFetcher{}
	values, err := valueFetcher.Fetch(containerInsightsNamespace, name, dims, metric.SAMPLE_COUNT, metric.MinuteStatPeriod)
	if err != nil {
		log.Println("failed to fetch metrics", err)
		return testResult
	}

	if !metric.IsAllValuesGreaterThanOrEqualToExpectedValue(name, values, 0) {
		return testResult
	}

	testResult.Status = status.SUCCESSFUL
	return testResult
}

func (e *EKSDaemonTestRunner) validateLogs(env *environment.MetaData) status.TestResult {
	testResult := status.TestResult{
		Name:   "emf-logs",
		Status: status.FAILED,
	}

	now := time.Now()
	group := fmt.Sprintf("/aws/containerinsights/%s/performance", env.EKSClusterName)

	// need to get the instances used for the EKS cluster
	eKSInstances, err := awsservice.GetEKSInstances(env.EKSClusterName)
	if err != nil {
		log.Println("failed to get EKS instances", err)
		return testResult
	}

	for _, instance := range eKSInstances {
		stream := *instance.InstanceName
		err = awsservice.ValidateLogs(
			group,
			stream,
			nil,
			&now,
			awsservice.AssertLogsNotEmpty(),
			awsservice.AssertNoDuplicateLogs(),
			awsservice.AssertPerLog(
				awsservice.AssertLogSchema(func(message string) (string, error) {
					var eksClusterType awsservice.EKSClusterType
					innerErr := json.Unmarshal([]byte(message), &eksClusterType)
					if innerErr != nil {
						return "", fmt.Errorf("failed to unmarshal log file: %w", innerErr)
					}

					log.Printf("eksClusterType is: %s", eksClusterType.Type)
					jsonSchema, ok := eks_resources.EksClusterValidationMap[eksClusterType.Type]
					if !ok {
						return "", errors.New("invalid cluster type provided")
					}
					return jsonSchema, nil
				}),
				awsservice.AssertLogContainsSubstring(fmt.Sprintf("\"ClusterName\":\"%s\"", env.EKSClusterName)),
			),
		)

		if err != nil {
			log.Printf("log validation (%s/%s) failed: %v", group, stream, err)
			return testResult
		}
	}

	testResult.Status = status.SUCCESSFUL
	return testResult
}

func (e *EKSDaemonTestRunner) GetTestName() string {
	return "EKSContainerInstance"
}

func (e *EKSDaemonTestRunner) GetAgentConfigFileName() string {
	return "" // TODO: maybe not needed?
}

func (e *EKSDaemonTestRunner) GetAgentRunDuration() time.Duration {
	return time.Minute * 3
}

func (e *EKSDaemonTestRunner) GetMeasuredMetrics() []string {
	return []string{
		"cluster_failed_node_count",
		"cluster_node_count",
		"namespace_number_of_running_pods",
		"node_cpu_limit",
		"node_cpu_reserved_capacity",
		"node_cpu_usage_total",
		"node_cpu_utilization",
		"node_filesystem_utilization",
		"node_memory_limit",
		"node_memory_reserved_capacity",
		"node_memory_utilization",
		"node_memory_working_set",
		"node_network_total_bytes",
		"node_number_of_running_containers",
		"node_number_of_running_pods",
		"pod_cpu_reserved_capacity",
		"pod_cpu_utilization",
		"pod_cpu_utilization_over_pod_limit",
		"pod_memory_reserved_capacity",
		"pod_memory_utilization",
		"pod_memory_utilization_over_pod_limit",
		"pod_network_rx_bytes",
		"pod_network_tx_bytes",
		"service_number_of_running_pods",
	}
}

func (t *EKSDaemonTestRunner) SetAgentConfig(config test_runner.AgentConfig) {}

func (e *EKSDaemonTestRunner) SetupAfterAgentRun() error {
	return nil
}

var _ test_runner.ITestRunner = (*EKSDaemonTestRunner)(nil)
