// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

//go:build !windows

package emf

import (
	"time"

	"github.com/aws/amazon-cloudwatch-agent-test/environment"
	. "github.com/aws/amazon-cloudwatch-agent-test/test/awsneuron/resources"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric"
	"github.com/aws/amazon-cloudwatch-agent-test/test/status"
	"github.com/aws/amazon-cloudwatch-agent-test/test/test_runner"
)

const (
	awsNeuronMetricIndicator = "_neuron"
)

var expectedDimsToMetrics = map[string][]string{
	"ClusterName": {
		//ContainerNeuronCoreUtil, ContainerNeuronCoreMemUsageConstants, ContainerNeuronCoreMemUsageModel, ContainerNeuronCoreMemUsageScratchpad,
		//ContainerNeuronCoreMemUsageRuntime, ContainerNeuronCoreMemUsageTensors, ContainerNeuronCoreMemUsageTotal, ContainerNeuronDeviceHwEccEvents,
		//
		//PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
		//PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal, PodNeuronDeviceHwEccEvents,

		NodeNeuronCoreUtil, NodeNeuronCoreMemUsageConstants, NodeNeuronCoreMemUsageModel, NodeNeuronCoreMemUsageScratchpad,
		NodeNeuronCoreMemUsageRuntime, NodeNeuronCoreMemUsageTensors, NodeNeuronCoreMemUsageTotal, NodeNeuronDeviceHwEccEvents,
		NodeExecutionErrorsTotal, NodeNeuronDeviceRuntimeMemoryUsed, NodeNeuronExecutionLatency,
	},
	//"ClusterName-Namespace": {
	//	PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
	//	PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal, PodNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-Service": {
	//	PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
	//	PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal, PodNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-PodName": {
	//	PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
	//	PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal, PodNeuronDeviceHwEccEvents,
	//},
	"ClusterName-InstanceId-NodeName": {
		NodeNeuronCoreUtil, NodeNeuronCoreMemUsageConstants, NodeNeuronCoreMemUsageModel, NodeNeuronCoreMemUsageScratchpad,
		NodeNeuronCoreMemUsageRuntime, NodeNeuronCoreMemUsageTensors, NodeNeuronCoreMemUsageTotal, NodeNeuronDeviceHwEccEvents,
		NodeExecutionErrorsTotal, NodeNeuronDeviceRuntimeMemoryUsed, NodeNeuronExecutionLatency,
	},
	//"ClusterName-Namespace-PodName-FullPodName": {
	//	PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
	//	PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal, PodNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-PodName-ContainerName": {
	//	ContainerNeuronCoreUtil, ContainerNeuronCoreMemUsageConstants, ContainerNeuronCoreMemUsageModel, ContainerNeuronCoreMemUsageScratchpad,
	//	ContainerNeuronCoreMemUsageRuntime, ContainerNeuronCoreMemUsageTensors, ContainerNeuronCoreMemUsageTotal, ContainerNeuronDeviceHwEccEvents,
	//},
	"ClusterName-InstanceId-NodeName-NeuronDevice": {
		NodeNeuronDeviceHwEccEvents,
	},
	//"ClusterName-Namespace-PodName-FullPodName-ContainerName": {
	//	ContainerNeuronCoreUtil, ContainerNeuronCoreMemUsageConstants, ContainerNeuronCoreMemUsageModel, ContainerNeuronCoreMemUsageScratchpad,
	//	ContainerNeuronCoreMemUsageRuntime, ContainerNeuronCoreMemUsageTensors, ContainerNeuronCoreMemUsageTotal, ContainerNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-PodName-FullPodName-NeuronDevice": {
	//	PodNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-PodName-FullPodName-NeuronDevice-NeuronCore": {
	//	PodNeuronCoreUtil, PodNeuronCoreMemUsageConstants, PodNeuronCoreMemUsageModel, PodNeuronCoreMemUsageScratchpad,
	//	PodNeuronCoreMemUsageRuntime, PodNeuronCoreMemUsageTensors, PodNeuronCoreMemUsageTotal,
	//},
	"ClusterName-InstanceId-NodeName-NeuronDevice-NeuronCore-InstanceType": {
		NodeNeuronCoreUtil, NodeNeuronCoreMemUsageConstants, NodeNeuronCoreMemUsageModel, NodeNeuronCoreMemUsageScratchpad,
		NodeNeuronCoreMemUsageRuntime, NodeNeuronCoreMemUsageTensors, NodeNeuronCoreMemUsageTotal,
	},
	//"ClusterName-Namespace-PodName-FullPodName-ContainerName-NeuronDevice": {
	//	ContainerNeuronDeviceHwEccEvents,
	//},
	//"ClusterName-Namespace-PodName-FullPodName-ContainerName-NeuronDevice-NeuronCore": {
	//	ContainerNeuronCoreUtil, ContainerNeuronCoreMemUsageConstants, ContainerNeuronCoreMemUsageModel, ContainerNeuronCoreMemUsageScratchpad,
	//	ContainerNeuronCoreMemUsageRuntime, ContainerNeuronCoreMemUsageTensors, ContainerNeuronCoreMemUsageTotal,
	//},
}

type AwsNeuronTestRunner struct {
	test_runner.BaseTestRunner
	testName string
	env      *environment.MetaData
}

var _ test_runner.ITestRunner = (*AwsNeuronTestRunner)(nil)

func (t *AwsNeuronTestRunner) Validate() status.TestGroupResult {
	var testResults []status.TestResult
	testResults = append(testResults, metric.ValidateMetrics(t.env, awsNeuronMetricIndicator, expectedDimsToMetrics)...)
	testResults = append(testResults, metric.ValidateLogs(t.env))
	return status.TestGroupResult{
		Name:        t.GetTestName(),
		TestResults: testResults,
	}
}

func (t *AwsNeuronTestRunner) GetTestName() string {
	return t.testName
}

func (t *AwsNeuronTestRunner) GetAgentConfigFileName() string {
	return ""
}

func (t *AwsNeuronTestRunner) GetAgentRunDuration() time.Duration {
	return 7 * time.Minute
}

func (t *AwsNeuronTestRunner) GetMeasuredMetrics() []string {
	return nil
}
