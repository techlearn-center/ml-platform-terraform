# Module 06: Pipeline Orchestration (Step Functions and Airflow)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Intermediate-Advanced |
| **Prerequisites** | Modules 01-05 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Design ML pipeline orchestration using AWS Step Functions
- Deploy Step Functions state machines with Terraform
- Create SageMaker Pipeline definitions for training workflows
- Understand when to use Step Functions vs. Airflow vs. SageMaker Pipelines
- Build an end-to-end pipeline: ingest, preprocess, train, evaluate, register
- Configure pipeline execution IAM roles with least privilege

---

## Concepts

### Why Pipeline Orchestration?

ML is not a single script -- it is a multi-step workflow. Without orchestration, you get:
- Manual, error-prone execution of sequential steps
- No retry logic when transient failures occur
- No visibility into which step failed or how long each step took
- Inability to schedule recurring training runs

### ML Pipeline Architecture

```
+-------------------------------------------------------------------+
|              ML Pipeline (Step Functions State Machine)             |
+-------------------------------------------------------------------+
|                                                                     |
|  [Start] --> [Ingest Data] --> [Validate Data] --> [Preprocess]    |
|                                                         |           |
|                                                         v           |
|              [Register Model] <-- [Evaluate] <-- [Train Model]     |
|                   |                                                 |
|                   v                                                 |
|              {Accuracy > 0.9?}                                      |
|              /            \                                         |
|           Yes              No                                       |
|            |                |                                       |
|            v                v                                       |
|      [Deploy to           [Send Alert]                              |
|       Endpoint]            [End]                                    |
|            |                                                        |
|            v                                                        |
|          [End]                                                      |
+-------------------------------------------------------------------+
```

### Orchestration Options Comparison

| Feature | Step Functions | SageMaker Pipelines | Airflow (MWAA) |
|---|---|---|---|
| **Best for** | General AWS workflows | SageMaker-native ML | Complex DAGs, Python logic |
| **Managed by** | AWS | AWS (SageMaker) | AWS (MWAA) or self-hosted |
| **Language** | ASL (JSON/YAML) | Python SDK | Python DAGs |
| **Pricing** | Per state transition | Per pipeline step | Per environment hour |
| **Terraform support** | Excellent | Good (via SDK) | Good (MWAA) |
| **Visual editor** | Yes (Workflow Studio) | Yes (Studio Pipeline) | Yes (Airflow UI) |

---

## Hands-On Lab

### Exercise 1: Deploy a Step Functions ML Pipeline

**Step 1:** Create the Step Functions state machine with Terraform:

```hcl
# terraform/modules/pipeline/main.tf

resource "aws_sfn_state_machine" "ml_pipeline" {
  name     = "${var.project_name}-${var.environment}-ml-pipeline"
  role_arn = var.pipeline_execution_role_arn

  definition = jsonencode({
    Comment = "ML Training Pipeline"
    StartAt = "PreprocessData"

    States = {
      PreprocessData = {
        Type     = "Task"
        Resource = "arn:aws:states:::sagemaker:createProcessingJob.sync"
        Parameters = {
          ProcessingJobName = "preprocess-${var.project_name}"
          "ProcessingInputs" = [{
            InputName = "input"
            S3Input = {
              S3Uri            = "s3://${var.data_bucket}/raw/"
              LocalPath        = "/opt/ml/processing/input"
              S3DataType       = "S3Prefix"
              S3InputMode      = "File"
            }
          }]
          "ProcessingOutputConfig" = {
            Outputs = [{
              OutputName = "output"
              S3Output = {
                S3Uri      = "s3://${var.data_bucket}/processed/"
                LocalPath  = "/opt/ml/processing/output"
                S3UploadMode = "EndOfJob"
              }
            }]
          }
          "ProcessingResources" = {
            ClusterConfig = {
              InstanceCount = 1
              InstanceType  = "ml.m5.xlarge"
              VolumeSizeInGB = 30
            }
          }
          RoleArn = var.sagemaker_role_arn
          AppSpecification = {
            ImageUri = var.processing_image_uri
          }
        }
        Next = "TrainModel"
      }

      TrainModel = {
        Type     = "Task"
        Resource = "arn:aws:states:::sagemaker:createTrainingJob.sync"
        Parameters = {
          TrainingJobName = "train-${var.project_name}"
          AlgorithmSpecification = {
            TrainingInputMode = "File"
            TrainingImage     = var.training_image_uri
          }
          RoleArn = var.sagemaker_role_arn
          InputDataConfig = [{
            ChannelName = "train"
            DataSource = {
              S3DataSource = {
                S3DataType = "S3Prefix"
                S3Uri      = "s3://${var.data_bucket}/processed/train/"
              }
            }
          }]
          OutputDataConfig = {
            S3OutputPath = "s3://${var.model_bucket}/training-output/"
          }
          ResourceConfig = {
            InstanceCount  = 1
            InstanceType   = var.training_instance_type
            VolumeSizeInGB = 50
          }
          StoppingCondition = {
            MaxRuntimeInSeconds = 3600
          }
          HyperParameters = {
            max_depth  = "5"
            eta        = "0.2"
            num_round  = "100"
            objective  = "binary:logistic"
          }
        }
        Next = "EvaluateModel"
      }

      EvaluateModel = {
        Type     = "Task"
        Resource = "arn:aws:states:::sagemaker:createProcessingJob.sync"
        Parameters = {
          ProcessingJobName = "evaluate-${var.project_name}"
          "ProcessingResources" = {
            ClusterConfig = {
              InstanceCount  = 1
              InstanceType   = "ml.m5.large"
              VolumeSizeInGB = 20
            }
          }
          RoleArn = var.sagemaker_role_arn
          AppSpecification = {
            ImageUri = var.processing_image_uri
          }
        }
        ResultPath = "$.EvaluationResult"
        Next       = "CheckAccuracy"
      }

      CheckAccuracy = {
        Type = "Choice"
        Choices = [{
          Variable           = "$.EvaluationResult.accuracy"
          NumericGreaterThan = 0.9
          Next               = "RegisterModel"
        }]
        Default = "SendAlert"
      }

      RegisterModel = {
        Type     = "Task"
        Resource = "arn:aws:states:::sagemaker:createModelPackage"
        Parameters = {
          ModelPackageGroupName   = "${var.project_name}-${var.environment}-models"
          ModelApprovalStatus     = "PendingManualApproval"
          ModelPackageDescription = "Auto-trained model from pipeline"
        }
        End = true
      }

      SendAlert = {
        Type     = "Task"
        Resource = "arn:aws:states:::sns:publish"
        Parameters = {
          TopicArn = var.alert_sns_topic_arn
          Message  = "Model accuracy below threshold. Review training metrics."
          Subject  = "ML Pipeline Alert: Low Model Accuracy"
        }
        End = true
      }
    }
  })

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.pipeline.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ml-pipeline"
  }
}

resource "aws_cloudwatch_log_group" "pipeline" {
  name              = "/aws/states/${var.project_name}-${var.environment}-ml-pipeline"
  retention_in_days = 30
}
```

### Exercise 2: Schedule Pipeline Execution

```hcl
# EventBridge rule to trigger the pipeline on a schedule
resource "aws_cloudwatch_event_rule" "pipeline_schedule" {
  name                = "${var.project_name}-${var.environment}-pipeline-schedule"
  description         = "Trigger ML pipeline for weekly retraining"
  schedule_expression = "rate(7 days)"
}

resource "aws_cloudwatch_event_target" "pipeline" {
  rule     = aws_cloudwatch_event_rule.pipeline_schedule.name
  arn      = aws_sfn_state_machine.ml_pipeline.arn
  role_arn = var.pipeline_execution_role_arn

  input = jsonencode({
    execution_date = "scheduled"
    environment    = var.environment
  })
}
```

### Exercise 3: Trigger Pipeline from Python

```python
# scripts/trigger_pipeline.py
import boto3
import json
from datetime import datetime
from dotenv import load_dotenv
import os

load_dotenv()

sfn_client = boto3.client("stepfunctions")

state_machine_arn = os.getenv("PIPELINE_STATE_MACHINE_ARN")

# Start a new execution
response = sfn_client.start_execution(
    stateMachineArn=state_machine_arn,
    name=f"training-{datetime.now().strftime('%Y%m%d-%H%M%S')}",
    input=json.dumps({
        "data_version": "2024-01-15",
        "hyperparameters": {
            "max_depth": 5,
            "eta": 0.2,
            "num_round": 100
        }
    }),
)

execution_arn = response["executionArn"]
print(f"Pipeline started: {execution_arn}")

# Monitor execution
import time
while True:
    status = sfn_client.describe_execution(executionArn=execution_arn)
    state = status["status"]
    print(f"Status: {state}")
    if state in ("SUCCEEDED", "FAILED", "TIMED_OUT", "ABORTED"):
        break
    time.sleep(30)

if state == "SUCCEEDED":
    output = json.loads(status["output"])
    print(f"Pipeline output: {json.dumps(output, indent=2)}")
else:
    print(f"Pipeline failed: {status.get('error', 'Unknown error')}")
```

### Exercise 4: SageMaker Pipelines Alternative

For SageMaker-native pipelines using the Python SDK:

```python
# scripts/sagemaker_pipeline.py
from sagemaker.workflow.pipeline import Pipeline
from sagemaker.workflow.steps import ProcessingStep, TrainingStep
from sagemaker.workflow.conditions import ConditionGreaterThan
from sagemaker.workflow.condition_step import ConditionStep
from sagemaker.workflow.parameters import ParameterString, ParameterFloat
from sagemaker.processing import ScriptProcessor
from sagemaker.estimator import Estimator
import sagemaker

session = sagemaker.Session()

# Define pipeline parameters
instance_type = ParameterString(name="TrainingInstanceType", default_value="ml.m5.xlarge")
accuracy_threshold = ParameterFloat(name="AccuracyThreshold", default_value=0.9)

# Processing step
processor = ScriptProcessor(
    image_uri="683313688378.dkr.ecr.us-east-1.amazonaws.com/sagemaker-scikit-learn:1.2-1-cpu-py3",
    role=os.getenv("SAGEMAKER_ROLE_ARN"),
    instance_count=1,
    instance_type="ml.m5.xlarge",
)

preprocess_step = ProcessingStep(
    name="PreprocessData",
    processor=processor,
    code="scripts/preprocess.py",
)

# Training step
estimator = Estimator(
    image_uri=sagemaker.image_uris.retrieve("xgboost", "us-east-1", "1.7-1"),
    role=os.getenv("SAGEMAKER_ROLE_ARN"),
    instance_count=1,
    instance_type=instance_type,
)

train_step = TrainingStep(name="TrainModel", estimator=estimator)

# Create and register the pipeline
pipeline = Pipeline(
    name="ml-platform-training-pipeline",
    parameters=[instance_type, accuracy_threshold],
    steps=[preprocess_step, train_step],
)

pipeline.upsert(role_arn=os.getenv("SAGEMAKER_ROLE_ARN"))
execution = pipeline.start()
print(f"Pipeline execution: {execution.describe()}")
```

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Missing `.sync` in Step Functions resource | Step completes before SageMaker job finishes | Use `createTrainingJob.sync` for synchronous execution |
| No `MaxRuntimeInSeconds` on training | Runaway training costs | Always set `StoppingCondition` |
| Pipeline role cannot pass SageMaker role | "AccessDenied" on `iam:PassRole` | Add `iam:PassRole` permission to pipeline role |
| No logging on state machine | Cannot debug failures | Configure `logging_configuration` |
| Hardcoded S3 paths | Pipeline breaks across environments | Use variables and `${var.environment}` |

---

## Self-Check Questions

1. When would you choose Step Functions over SageMaker Pipelines for ML orchestration?
2. What does the `.sync` suffix do in Step Functions task resources?
3. How does the Choice state enable conditional model deployment?
4. Why do we set `MaxRuntimeInSeconds` on training jobs?
5. How would you add a human approval step before deploying a model to production?

---

## You Know You Have Completed This Module When...

- [ ] Step Functions state machine is deployed with Terraform
- [ ] Pipeline includes preprocess, train, evaluate, and conditional deploy steps
- [ ] EventBridge rule schedules weekly pipeline execution
- [ ] Python script can trigger and monitor pipeline execution
- [ ] Pipeline logs are visible in CloudWatch
- [ ] Validation script passes: `bash modules/06-data-storage/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: Step Functions execution fails on first step**
```bash
# Check the execution history
aws stepfunctions get-execution-history \
  --execution-arn <execution_arn> \
  --query 'events[?type==`TaskFailed`].{Error:taskFailedEventDetails.error,Cause:taskFailedEventDetails.cause}'
```

**Issue: SageMaker job fails with "ClientError"**
```bash
# Check the SageMaker job logs
aws logs tail /aws/sagemaker/TrainingJobs --follow \
  --filter-pattern "ERROR"
```

**Issue: Pipeline role permissions error**
```bash
# Verify the pipeline role can pass the SageMaker role
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw pipeline_execution_role_arn) \
  --action-names iam:PassRole \
  --resource-arns $(terraform output -raw sagemaker_execution_role_arn)
```

---

**Next: [Module 07 - Monitoring and Observability -->](../07-monitoring-infrastructure/)**
