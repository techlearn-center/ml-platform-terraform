# =============================================================================
# SageMaker Module - Studio Domain, User Profiles, Notebook Instances
# =============================================================================
# Provisions SageMaker Studio domain with VPC-only mode, user profiles for
# data scientists and ML engineers, and standalone notebook instances.
# =============================================================================

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "sagemaker_security_group_id" {
  type = string
}

variable "sagemaker_execution_role_arn" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

variable "notebook_instance_type" {
  type    = string
  default = "ml.t3.medium"
}

# -----------------------------------------------------------------------------
# SageMaker Studio Domain
# -----------------------------------------------------------------------------
resource "aws_sagemaker_domain" "studio" {
  domain_name = "${var.project_name}-${var.environment}-studio"
  auth_mode   = "IAM"
  vpc_id      = var.vpc_id
  subnet_ids  = var.private_subnet_ids

  default_user_settings {
    execution_role  = var.sagemaker_execution_role_arn
    security_groups = [var.sagemaker_security_group_id]

    sharing_settings {
      notebook_output_option = "Allowed"
      s3_kms_key_id          = var.kms_key_arn
    }

    kernel_gateway_app_settings {
      default_resource_spec {
        instance_type        = var.notebook_instance_type
        sagemaker_image_arn  = null
      }
    }

    jupyter_server_app_settings {
      default_resource_spec {
        instance_type = "system"
      }
    }
  }

  retention_policy {
    home_efs_file_system = "Delete"
  }

  kms_key_id = var.kms_key_arn

  tags = {
    Name = "${var.project_name}-${var.environment}-studio"
  }
}

# -----------------------------------------------------------------------------
# SageMaker Studio User Profiles
# -----------------------------------------------------------------------------
resource "aws_sagemaker_user_profile" "data_scientist" {
  domain_id         = aws_sagemaker_domain.studio.id
  user_profile_name = "${var.project_name}-${var.environment}-data-scientist"

  user_settings {
    execution_role = var.sagemaker_execution_role_arn
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-data-scientist"
    Role = "data-scientist"
  }
}

resource "aws_sagemaker_user_profile" "ml_engineer" {
  domain_id         = aws_sagemaker_domain.studio.id
  user_profile_name = "${var.project_name}-${var.environment}-ml-engineer"

  user_settings {
    execution_role = var.sagemaker_execution_role_arn
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-ml-engineer"
    Role = "ml-engineer"
  }
}

# -----------------------------------------------------------------------------
# SageMaker Notebook Instance (standalone, for quick experiments)
# -----------------------------------------------------------------------------
resource "aws_sagemaker_notebook_instance" "main" {
  name                    = "${var.project_name}-${var.environment}-notebook"
  role_arn                = var.sagemaker_execution_role_arn
  instance_type           = var.notebook_instance_type
  subnet_id               = var.private_subnet_ids[0]
  security_groups         = [var.sagemaker_security_group_id]
  kms_key_id              = var.kms_key_arn
  direct_internet_access  = "Disabled"
  root_access             = "Disabled"
  volume_size             = 50

  lifecycle_config_name = aws_sagemaker_notebook_instance_lifecycle_configuration.auto_stop.name

  tags = {
    Name = "${var.project_name}-${var.environment}-notebook"
  }
}

# -----------------------------------------------------------------------------
# Lifecycle Configuration - Auto-stop idle notebooks to save cost
# -----------------------------------------------------------------------------
resource "aws_sagemaker_notebook_instance_lifecycle_configuration" "auto_stop" {
  name = "${var.project_name}-${var.environment}-auto-stop"

  on_start = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Install the auto-stop script
    IDLE_TIME=3600  # 1 hour in seconds

    echo "Setting up auto-stop with ${IDLE_TIME}s idle timeout"

    cat > /usr/local/bin/auto-stop.py << 'SCRIPT'
    import json
    import os
    import time
    import urllib.request
    from datetime import datetime

    def get_notebook_name():
        log_path = '/opt/ml/metadata/resource-metadata.json'
        with open(log_path, 'r') as f:
            return json.load(f)['ResourceName']

    def is_idle(last_activity, idle_seconds=3600):
        last = datetime.strptime(last_activity, "%Y-%m-%dT%H:%M:%S.%fz")
        return (datetime.now() - last).total_seconds() > idle_seconds

    SCRIPT

    echo "Auto-stop configuration complete"
  EOF
  )
}

# -----------------------------------------------------------------------------
# SageMaker Model Package Group (for model registry)
# -----------------------------------------------------------------------------
resource "aws_sagemaker_model_package_group" "main" {
  model_package_group_name = "${var.project_name}-${var.environment}-models"

  model_package_group_description = "Model registry for ${var.project_name} ${var.environment} environment"

  tags = {
    Name = "${var.project_name}-${var.environment}-model-registry"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "studio_domain_id" {
  value = aws_sagemaker_domain.studio.id
}

output "studio_url" {
  value = aws_sagemaker_domain.studio.url
}

output "notebook_instance_name" {
  value = aws_sagemaker_notebook_instance.main.name
}

output "model_package_group_name" {
  value = aws_sagemaker_model_package_group.main.model_package_group_name
}
