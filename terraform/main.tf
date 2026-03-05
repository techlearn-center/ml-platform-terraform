# =============================================================================
# ML Platform - Root Terraform Configuration
# =============================================================================
# This root module orchestrates all sub-modules to deploy a complete
# ML platform on AWS including VPC networking, SageMaker, MLflow,
# S3 data lake, and IAM roles.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "ml-platform-tfstate"
    key            = "ml-platform/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "ml-platform-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# -----------------------------------------------------------------------------
# Data Sources
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# VPC Module - Networking foundation for all ML workloads
# -----------------------------------------------------------------------------
module "vpc" {
  source = "./modules/vpc"

  project_name       = var.project_name
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
}

# -----------------------------------------------------------------------------
# IAM Module - Roles and policies for SageMaker, MLflow, pipelines
# -----------------------------------------------------------------------------
module "iam" {
  source = "./modules/iam"

  project_name         = var.project_name
  environment          = var.environment
  data_bucket_arn      = module.s3.data_lake_bucket_arn
  model_bucket_arn     = module.s3.model_artifacts_bucket_arn
  mlflow_bucket_arn    = module.s3.mlflow_artifacts_bucket_arn
  feature_store_arn    = module.s3.feature_store_bucket_arn
  sagemaker_kms_key_arn = aws_kms_key.sagemaker.arn
}

# -----------------------------------------------------------------------------
# S3 Module - Data lake, model artifacts, feature store, MLflow artifacts
# -----------------------------------------------------------------------------
module "s3" {
  source = "./modules/s3"

  project_name = var.project_name
  environment  = var.environment
  kms_key_arn  = aws_kms_key.sagemaker.arn
}

# -----------------------------------------------------------------------------
# SageMaker Module - Studio domain, user profiles, notebook instances
# -----------------------------------------------------------------------------
module "sagemaker" {
  source = "./modules/sagemaker"

  project_name               = var.project_name
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  sagemaker_security_group_id = module.vpc.sagemaker_security_group_id
  sagemaker_execution_role_arn = module.iam.sagemaker_execution_role_arn
  kms_key_arn                = aws_kms_key.sagemaker.arn
  notebook_instance_type     = var.notebook_instance_type
}

# -----------------------------------------------------------------------------
# MLflow Module - Tracking server on ECS Fargate with RDS backend
# -----------------------------------------------------------------------------
module "mlflow" {
  source = "./modules/mlflow"

  project_name               = var.project_name
  environment                = var.environment
  vpc_id                     = module.vpc.vpc_id
  private_subnet_ids         = module.vpc.private_subnet_ids
  public_subnet_ids          = module.vpc.public_subnet_ids
  mlflow_security_group_id   = module.vpc.mlflow_security_group_id
  rds_security_group_id      = module.vpc.rds_security_group_id
  mlflow_bucket_name         = module.s3.mlflow_artifacts_bucket_name
  mlflow_execution_role_arn  = module.iam.mlflow_execution_role_arn
  mlflow_task_role_arn       = module.iam.mlflow_task_role_arn
  db_instance_class          = var.mlflow_db_instance_class
  mlflow_container_cpu       = var.mlflow_container_cpu
  mlflow_container_memory    = var.mlflow_container_memory
}

# -----------------------------------------------------------------------------
# KMS Key for encrypting SageMaker and ML data at rest
# -----------------------------------------------------------------------------
resource "aws_kms_key" "sagemaker" {
  description             = "${var.project_name}-${var.environment}-sagemaker-key"
  deletion_window_in_days = 10
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountFullAccess"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "AllowSageMakerUse"
        Effect = "Allow"
        Principal = {
          AWS = module.iam.sagemaker_execution_role_arn
        }
        Action = [
          "kms:Decrypt",
          "kms:Encrypt",
          "kms:GenerateDataKey",
          "kms:ReEncryptFrom",
          "kms:ReEncryptTo",
          "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${var.project_name}-${var.environment}-sagemaker-kms"
  }
}

resource "aws_kms_alias" "sagemaker" {
  name          = "alias/${var.project_name}-${var.environment}-sagemaker"
  target_key_id = aws_kms_key.sagemaker.key_id
}
