package hyperpod

import (
	"fmt"
	"github.com/aws/amazon-cloudwatch-agent-test/environment"
	"github.com/aws/amazon-cloudwatch-agent-test/environment/computetype"
	"github.com/aws/amazon-cloudwatch-agent-test/test/metric/dimension"
	"github.com/aws/amazon-cloudwatch-agent-test/test/status"
	"github.com/aws/amazon-cloudwatch-agent-test/test/test_runner"
	"github.com/stretchr/testify/suite"
	"log"
	"testing"
)

type HyperPodTestSuite struct {
	suite.Suite
	test_runner.TestSuite
}

func (suite *HyperPodTestSuite) SetupSuite() {
	fmt.Println(">>>> Starting AWS HyperPod Cluster Container Insights TestSuite")
}

func (suite *HyperPodTestSuite) TearDownSuite() {
	suite.Result.Print()
	fmt.Println(">>>> Finished AWS HyperPod Cluster Container Insights TestSuite")
}

func init() {
	environment.RegisterEnvironmentMetaDataFlags()
}

var (
	eksTestRunners []*test_runner.EKSTestRunner
)

func getEksTestRunners(env *environment.MetaData) []*test_runner.EKSTestRunner {
	if eksTestRunners == nil {
		factory := dimension.GetDimensionFactory(*env)

		eksTestRunners = []*test_runner.EKSTestRunner{
			{
				Runner: &HyperPodTestSuite{test_runner.BaseTestRunner{DimensionFactory: factory}, "EKS_AWS_HYPERPOD", env},
				Env:    *env,
			},
		}
	}
	return eksTestRunners
}

func (suite *HyperPodTestSuite) TestAllInSuite() {
	env := environment.GetEnvironmentMetaData()
	switch env.ComputeType {
	case computetype.EKS:
		log.Println("Environment compute type is EKS")
		for _, testRunner := range getEksTestRunners(env) {
			testRunner.Run(suite, env)
		}
	default:
		return
	}

	suite.Assert().Equal(status.SUCCESSFUL, suite.Result.GetStatus(), "AWS HyperPod Test Suite Failed")
}

func (suite *HyperPodTestSuite) AddToSuiteResult(r status.TestGroupResult) {
	suite.Result.TestGroupResults = append(suite.Result.TestGroupResults, r)
}

func TestAWSHyperPodSuite(t *testing.T) {
	suite.Run(t, new(HyperPodTestSuite))
}
