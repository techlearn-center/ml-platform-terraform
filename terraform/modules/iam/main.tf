# =============================================================================
# IAM Module - Roles for SageMaker, MLflow, Pipeline Execution
# =============================================================================
# Creates IAM roles with least-privilege policies for:
#   - SageMaker execution (training, inference, notebook access)
#   - MLflow ECS tasks (S3 artifact access, Secrets Manager)
#   - Pipeline execution (Step Functions / Airflow orchestration)
# =============================================================================

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "data_bucket_arn" {
  type = string
}

variable "model_bucket_arn" {
  type = string
}

variable "mlflow_bucket_arn" {
  type = string
}

variable "feature_store_arn" {
  type = string
}

variable "sagemaker_kms_key_arn" {
  type = string
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# SageMaker Execution Role
# -----------------------------------------------------------------------------
resource "aws_iam_role" "sagemaker_execution" {
  name = "${var.project_name}-${var.environment}-sagemaker-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "sagemaker.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-sagemaker-execution"
  }
}

resource "aws_iam_role_policy" "sagemaker_s3_access" {
  name = "${var.project_name}-${var.environment}-sagemaker-s3"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3DataAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.data_bucket_arn,
          "${var.data_bucket_arn}/*",
          var.model_bucket_arn,
          "${var.model_bucket_arn}/*",
          var.feature_store_arn,
          "${var.feature_store_arn}/*",
          var.mlflow_bucket_arn,
          "${var.mlflow_bucket_arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_role_policy" "sagemaker_ecr_access" {
  name = "${var.project_name}-${var.environment}-sagemaker-ecr"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ECRAccess"
        Effect = "Allow"
        Action = [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "sagemaker_kms_access" {
  name = "${var.project_name}-${var.environment}-sagemaker-kms"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSAccess"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:DescribeKey"
        ]
        Resource = [var.sagemaker_kms_key_arn]
      }
    ]
  })
}

resource "aws_iam_role_policy" "sagemaker_cloudwatch" {
  name = "${var.project_name}-${var.environment}-sagemaker-cw"
  role = aws_iam_role.sagemaker_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ]
        Resource = "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/sagemaker/*"
      },
      {
        Sid    = "CloudWatchMetrics"
        Effect = "Allow"
        Action = [
          "cloudwatch:PutMetricData"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "cloudwatch:namespace" = [
              "/aws/sagemaker/TrainingJobs",
              "/aws/sagemaker/Endpoints",
              "/aws/sagemaker/ProcessingJobs"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "sagemaker_full" {
  role       = aws_iam_role.sagemaker_execution.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSageMakerFullAccess"
}

# -----------------------------------------------------------------------------
# MLflow ECS Execution Role (for pulling images, writing logs)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "mlflow_execution" {
  name = "${var.project_name}-${var.environment}-mlflow-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-execution"
  }
}

resource "aws_iam_role_policy_attachment" "mlflow_execution_policy" {
  role       = aws_iam_role.mlflow_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "mlflow_secrets" {
  name = "${var.project_name}-${var.environment}-mlflow-secrets"
  role = aws_iam_role.mlflow_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-${var.environment}-*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# MLflow ECS Task Role (runtime permissions for the MLflow container)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "mlflow_task" {
  name = "${var.project_name}-${var.environment}-mlflow-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-task"
  }
}

resource "aws_iam_role_policy" "mlflow_s3_access" {
  name = "${var.project_name}-${var.environment}-mlflow-s3"
  role = aws_iam_role.mlflow_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "MLflowArtifactAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.mlflow_bucket_arn,
          "${var.mlflow_bucket_arn}/*"
        ]
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Pipeline Execution Role (for Step Functions / Airflow)
# -----------------------------------------------------------------------------
resource "aws_iam_role" "pipeline_execution" {
  name = "${var.project_name}-${var.environment}-pipeline-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = [
            "states.amazonaws.com",
            "sagemaker.amazonaws.com"
          ]
        }
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-pipeline-execution"
  }
}

resource "aws_iam_role_policy" "pipeline_sagemaker" {
  name = "${var.project_name}-${var.environment}-pipeline-sagemaker"
  role = aws_iam_role.pipeline_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SageMakerPipelineAccess"
        Effect = "Allow"
        Action = [
          "sagemaker:CreateTrainingJob",
          "sagemaker:DescribeTrainingJob",
          "sagemaker:CreateProcessingJob",
          "sagemaker:DescribeProcessingJob",
          "sagemaker:CreateModel",
          "sagemaker:CreateEndpoint",
          "sagemaker:CreateEndpointConfig",
          "sagemaker:UpdateEndpoint",
          "sagemaker:DescribeEndpoint",
          "sagemaker:InvokeEndpoint",
          "sagemaker:CreateModelPackage",
          "sagemaker:DescribeModelPackage"
        ]
        Resource = "*"
      },
      {
        Sid    = "PassRole"
        Effect = "Allow"
        Action = "iam:PassRole"
        Resource = [
          aws_iam_role.sagemaker_execution.arn
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "sagemaker.amazonaws.com"
          }
        }
      },
      {
        Sid    = "S3PipelineAccess"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.data_bucket_arn,
          "${var.data_bucket_arn}/*",
          var.model_bucket_arn,
          "${var.model_bucket_arn}/*"
        ]
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "*"
      }
    ]
  })
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "sagemaker_execution_role_arn" {
  value = aws_iam_role.sagemaker_execution.arn
}

output "sagemaker_execution_role_name" {
  value = aws_iam_role.sagemaker_execution.name
}

output "mlflow_execution_role_arn" {
  value = aws_iam_role.mlflow_execution.arn
}

output "mlflow_task_role_arn" {
  value = aws_iam_role.mlflow_task.arn
}

output "pipeline_execution_role_arn" {
  value = aws_iam_role.pipeline_execution.arn
}
