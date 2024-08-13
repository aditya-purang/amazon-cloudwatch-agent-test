package hyperpod

import (
	"github.com/aws/amazon-cloudwatch-agent-test/environment"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric"
	"github.com/aws/amazon-cloudwatch-agent-test/test/status"
	"github.com/aws/amazon-cloudwatch-agent-test/test/test_runner"
	"time"
)

const (
	awsHyperPodMetricIndicator = "_hyperpod"
)

const (
	UnschedulablePendingReplacementMetric = "hyper_pod_node_health_status_unschedulable_pending_replacement"
	UnschedulablePendingRebootMetric      = "hyper_pod_node_health_status_unschedulable_pending_reboot"
	SchedulableMetric                     = "hyper_pod_node_health_status_schedulable"
	UnschedulableMetric                   = "hyper_pod_node_health_status_unschedulable"
)

var expectedDimsToMetrics = map[string][]string{
	"ClusterName": {
		UnschedulablePendingReplacementMetric, UnschedulablePendingRebootMetric, SchedulableMetric,
		UnschedulableMetric,
	},
	"ClusterName-InstanceId-NodeName": {
		UnschedulablePendingReplacementMetric, UnschedulablePendingRebootMetric, SchedulableMetric,
		UnschedulableMetric,
	},
}

type AwsHyperPodTestRunner struct {
	test_runner.BaseTestRunner
	testName string
	env      *environment.MetaData
}

var _ test_runner.ITestRunner = (*AwsHyperPodTestRunner)(nil)

func (t *AwsHyperPodTestRunner) Validate() status.TestGroupResult {
	var testResults []status.TestResult
	testResults = append(testResults, metric.ValidateMetrics(t.env, awsHyperPodMetricIndicator, expectedDimsToMetrics)...)
	testResults = append(testResults, metric.ValidateLogs(t.env))
	return status.TestGroupResult{
		Name:        t.GetTestName(),
		TestResults: testResults,
	}
}

func (t *AwsHyperPodTestRunner) GetTestName() string {
	return t.testName
}

func (t *AwsHyperPodTestRunner) GetAgentConfigFileName() string {
	return ""
}

func (t *AwsHyperPodTestRunner) GetAgentRunDuration() time.Duration {
	return 50 * time.Minute
}

func (t *AwsHyperPodTestRunner) GetMeasuredMetrics() []string {
	return nil
}
