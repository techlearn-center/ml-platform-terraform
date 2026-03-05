# =============================================================================
# ML Platform - Output Values
# =============================================================================

# -----------------------------------------------------------------------------
# VPC Outputs
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "ID of the ML platform VPC"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "IDs of private subnets for ML workloads"
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "IDs of public subnets for load balancers"
  value       = module.vpc.public_subnet_ids
}

# -----------------------------------------------------------------------------
# SageMaker Outputs
# -----------------------------------------------------------------------------
output "sagemaker_studio_domain_id" {
  description = "SageMaker Studio domain ID"
  value       = module.sagemaker.studio_domain_id
}

output "sagemaker_studio_url" {
  description = "SageMaker Studio domain URL"
  value       = module.sagemaker.studio_url
}

output "sagemaker_notebook_instance_name" {
  description = "SageMaker notebook instance name"
  value       = module.sagemaker.notebook_instance_name
}

output "sagemaker_execution_role_arn" {
  description = "ARN of the SageMaker execution role"
  value       = module.iam.sagemaker_execution_role_arn
}

# -----------------------------------------------------------------------------
# MLflow Outputs
# -----------------------------------------------------------------------------
output "mlflow_tracking_uri" {
  description = "MLflow tracking server URI (ALB DNS)"
  value       = module.mlflow.tracking_uri
}

output "mlflow_rds_endpoint" {
  description = "MLflow RDS PostgreSQL endpoint"
  value       = module.mlflow.rds_endpoint
  sensitive   = true
}

# -----------------------------------------------------------------------------
# S3 Bucket Outputs
# -----------------------------------------------------------------------------
output "data_lake_bucket_name" {
  description = "S3 bucket name for the data lake"
  value       = module.s3.data_lake_bucket_name
}

output "data_lake_bucket_arn" {
  description = "S3 bucket ARN for the data lake"
  value       = module.s3.data_lake_bucket_arn
}

output "model_artifacts_bucket_name" {
  description = "S3 bucket name for model artifacts"
  value       = module.s3.model_artifacts_bucket_name
}

output "model_artifacts_bucket_arn" {
  description = "S3 bucket ARN for model artifacts"
  value       = module.s3.model_artifacts_bucket_arn
}

output "feature_store_bucket_name" {
  description = "S3 bucket name for the feature store"
  value       = module.s3.feature_store_bucket_name
}

output "mlflow_artifacts_bucket_name" {
  description = "S3 bucket name for MLflow artifacts"
  value       = module.s3.mlflow_artifacts_bucket_name
}

# -----------------------------------------------------------------------------
# IAM Role Outputs
# -----------------------------------------------------------------------------
output "sagemaker_role_arn" {
  description = "ARN of the SageMaker execution IAM role"
  value       = module.iam.sagemaker_execution_role_arn
}

output "mlflow_execution_role_arn" {
  description = "ARN of the MLflow ECS execution IAM role"
  value       = module.iam.mlflow_execution_role_arn
}

output "pipeline_execution_role_arn" {
  description = "ARN of the pipeline execution IAM role"
  value       = module.iam.pipeline_execution_role_arn
}

# -----------------------------------------------------------------------------
# KMS Outputs
# -----------------------------------------------------------------------------
output "kms_key_arn" {
  description = "ARN of the KMS key used for ML data encryption"
  value       = aws_kms_key.sagemaker.arn
}

output "kms_key_alias" {
  description = "Alias of the KMS key"
  value       = aws_kms_alias.sagemaker.name
}
