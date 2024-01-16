// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
// SPDX-License-Identifier: MIT

//go:build !windows

package metric_value_benchmark

import (
	"log"

	"github.com/aws/amazon-cloudwatch-agent-test/test/metric"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric/dimension"
	"github.com/aws/amazon-cloudwatch-agent-test/test/status"
	"github.com/aws/amazon-cloudwatch-agent-test/test/test_runner"
	"github.com/aws/amazon-cloudwatch-agent-test/util/common"
)

const jmxNamespace = "MetricValueBenchmarkJMXTest"

type JMXTestRunner struct {
	test_runner.BaseTestRunner
}

var _ test_runner.ITestRunner = (*JMXTestRunner)(nil)

func (t *JMXTestRunner) Validate() status.TestGroupResult {
	metricsToFetch := t.GetMeasuredMetrics()
	testResults := make([]status.TestResult, len(metricsToFetch))
	for i, metricName := range metricsToFetch {
		testResults[i] = t.validateJMXMetric(metricName)
	}

	return status.TestGroupResult{
		Name:        t.GetTestName(),
		TestResults: testResults,
	}
}

func (t *JMXTestRunner) GetTestName() string {
	return "JMX"
}

func (t *JMXTestRunner) GetAgentConfigFileName() string {
	return "jmx_config.json"
}

func (t *JMXTestRunner) SetupBeforeAgentRun() error {
	err := t.BaseTestRunner.SetupBeforeAgentRun()
	if err != nil {
		return err
	}

	log.Println("set up zookeeper and kafka")
	startJMXCommands := []string{
		"curl https://dlcdn.apache.org/zookeeper/zookeeper-3.8.4/apache-zookeeper-3.8.4-bin.tar.gz -o apache-zookeeper-3.8.4-bin.tar.gz",
		"tar -xzf apache-zookeeper-3.8.4-bin.tar.gz",
		"mkdir apache-zookeeper-3.8.4-bin/data",
		"touch apache-zookeeper-3.8.4-bin/conf/zoo.cfg",
		"echo -e 'tickTime = 2000\ndataDir = ../data\nclientPort = 2181\ninitLimit = 5\nsyncLimit = 2\n' >> apache-zookeeper-3.8.4-bin/conf/zoo.cfg",
		"apache-zookeeper-3.8.4-bin/bin/zkServer.sh start",
		"curl https://dlcdn.apache.org/kafka/3.6.2/kafka_2.13-3.6.2.tgz -o kafka_2.13-3.6.2.tgz",
		"tar -xzf kafka_2.13-3.6.2.tgz",
		"echo 'KAFKA_JMX_OPTS=\"-Dcom.sun.management.jmxremote.port=2020 -Dcom.sun.management.jmxremote.rmi.port=2021 -Djava.rmi.server.hostname=localhost -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false\"'|cat - kafka_2.13-3.6.2/bin/kafka-run-class.sh > /tmp/kafka-jmx-config && mv /tmp/kafka-jmx-config kafka_2.13-3.6.2/bin/kafka-run-class.sh",
		"sudo chmod +x kafka_2.13-3.6.2/bin/kafka-run-class.sh",
		"kafka_2.13-3.6.2/bin/kafka-server-start.sh kafka_2.13-3.6.2/config/server.properties > /tmp/kafka-jar-logs.txt 2>&1 &",
		"nohup java -Dcom.sun.management.jmxremote -Dcom.sun.management.jmxremote.port=2030 -Dcom.sun.management.jmxremote.local.only=false -Dcom.sun.management.jmxremote.authenticate=false -Dcom.sun.management.jmxremote.ssl=false -Dcom.sun.management.jmxremote.rmi.port=2030  -Dcom.sun.management.jmxremote.host=0.0.0.0  -Djava.rmi.server.hostname=0.0.0.0 -Dserver.port=8090 -Dspring.application.admin.enabled=true -jar jars/spring-boot-web-starter-tomcat.jar > /tmp/spring-boot-web-starter-tomcat-jar.txt 2>&1 &",
	}

	err = common.RunCommands(startJMXCommands)
	if err != nil {
		return err
	}
	return nil
}

func (t *JMXTestRunner) GetMeasuredMetrics() []string {
	return []string{
		"jvm.memory.heap.used",
		"jvm.threads.count",
		"jvm.gc.collections.elapsed",
		"jvm.gc.collections.elapsed",
		"kafka.request.count",
		"kafka.request.time.50p",
		"kafka.network.io",
		"tomcat.sessions",
		"tomcat.errors",
		"tomcat.processing_time",
		"tomcat.request_count",
	}
}

func (t *JMXTestRunner) validateJMXMetric(metricName string) status.TestResult {
	testResult := status.TestResult{
		Name:   metricName,
		Status: status.FAILED,
	}

	dims, failed := t.DimensionFactory.GetDimensions([]dimension.Instruction{
		{
			Key:   "InstanceId",
			Value: dimension.UnknownDimensionValue(),
		},
	})

	if len(failed) > 0 {
		return testResult
	}

	fetcher := metric.MetricValueFetcher{}
	values, err := fetcher.Fetch(jmxNamespace, metricName, dims, metric.AVERAGE, metric.HighResolutionStatPeriod)
	log.Printf("metric values are %v", values)
	if err != nil {
		log.Printf("err: %v\n", err)
		return testResult
	}

	if !metric.IsAllValuesGreaterThanOrEqualToExpectedValue(metricName, values, 0) {
		return testResult
	}

	testResult.Status = status.SUCCESSFUL
	return testResult
}
