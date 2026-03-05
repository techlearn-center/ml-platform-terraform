# =============================================================================
# ML Platform - Input Variables
# =============================================================================

# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "ml-platform"

  validation {
    condition     = can(regex("^[a-z0-9-]+$", var.project_name))
    error_message = "Project name must contain only lowercase letters, numbers, and hyphens."
  }
}

variable "environment" {
  description = "Deployment environment (dev, staging, prod)"
  type        = string
  default     = "dev"

  validation {
    condition     = contains(["dev", "staging", "prod"], var.environment)
    error_message = "Environment must be one of: dev, staging, prod."
  }
}

# -----------------------------------------------------------------------------
# VPC / Networking
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "availability_zones" {
  description = "List of availability zones to use"
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b", "us-east-1c"]
}

# -----------------------------------------------------------------------------
# SageMaker
# -----------------------------------------------------------------------------
variable "notebook_instance_type" {
  description = "EC2 instance type for SageMaker notebook instances"
  type        = string
  default     = "ml.t3.medium"

  validation {
    condition     = can(regex("^ml\\.", var.notebook_instance_type))
    error_message = "Notebook instance type must start with 'ml.' prefix."
  }
}

variable "training_instance_type" {
  description = "EC2 instance type for SageMaker training jobs"
  type        = string
  default     = "ml.m5.xlarge"
}

variable "endpoint_instance_type" {
  description = "EC2 instance type for SageMaker inference endpoints"
  type        = string
  default     = "ml.m5.large"
}

variable "sagemaker_studio_user_profiles" {
  description = "List of SageMaker Studio user profile names to create"
  type        = list(string)
  default     = ["data-scientist-1", "ml-engineer-1"]
}

# -----------------------------------------------------------------------------
# MLflow
# -----------------------------------------------------------------------------
variable "mlflow_db_instance_class" {
  description = "RDS instance class for MLflow backend database"
  type        = string
  default     = "db.t3.small"
}

variable "mlflow_container_cpu" {
  description = "CPU units for the MLflow ECS Fargate container (1024 = 1 vCPU)"
  type        = number
  default     = 512
}

variable "mlflow_container_memory" {
  description = "Memory (MiB) for the MLflow ECS Fargate container"
  type        = number
  default     = 1024
}

# -----------------------------------------------------------------------------
# Cost Management
# -----------------------------------------------------------------------------
variable "budget_limit_monthly" {
  description = "Monthly budget limit in USD for cost alerts"
  type        = number
  default     = 500
}

variable "alert_email" {
  description = "Email address for budget and monitoring alerts"
  type        = string
  default     = "ml-team@example.com"
}
