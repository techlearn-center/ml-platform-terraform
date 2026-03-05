# =============================================================================
# S3 Module - Data Lake, Model Artifacts, Feature Store, MLflow Artifacts
# =============================================================================
# Creates encrypted S3 buckets with lifecycle policies for ML platform storage:
#   - Data lake: raw, processed, and curated data tiers
#   - Model artifacts: trained model binaries and metadata
#   - Feature store: precomputed feature datasets
#   - MLflow artifacts: experiment tracking artifacts
# =============================================================================

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "kms_key_arn" {
  type = string
}

data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# Data Lake Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "data_lake" {
  bucket = "${var.project_name}-${var.environment}-data-lake-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-data-lake"
    Purpose = "data-lake"
  }
}

resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id

  rule {
    id     = "transition-to-ia"
    status = "Enabled"

    filter {
      prefix = "raw/"
    }

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }
  }

  rule {
    id     = "expire-temp-data"
    status = "Enabled"

    filter {
      prefix = "tmp/"
    }

    expiration {
      days = 7
    }
  }
}

# Create data lake folder structure
resource "aws_s3_object" "data_lake_folders" {
  for_each = toset(["raw/", "processed/", "curated/", "tmp/"])

  bucket  = aws_s3_bucket.data_lake.id
  key     = each.value
  content = ""
}

# -----------------------------------------------------------------------------
# Model Artifacts Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "model_artifacts" {
  bucket = "${var.project_name}-${var.environment}-model-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-model-artifacts"
    Purpose = "model-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "model_artifacts" {
  bucket = aws_s3_bucket.model_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# Feature Store Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "feature_store" {
  bucket = "${var.project_name}-${var.environment}-feature-store-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-feature-store"
    Purpose = "feature-store"
  }
}

resource "aws_s3_bucket_versioning" "feature_store" {
  bucket = aws_s3_bucket.feature_store.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "feature_store" {
  bucket = aws_s3_bucket.feature_store.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "feature_store" {
  bucket = aws_s3_bucket.feature_store.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# -----------------------------------------------------------------------------
# MLflow Artifacts Bucket
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "mlflow_artifacts" {
  bucket = "${var.project_name}-${var.environment}-mlflow-artifacts-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-mlflow-artifacts"
    Purpose = "mlflow-artifacts"
  }
}

resource "aws_s3_bucket_versioning" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "mlflow_artifacts" {
  bucket = aws_s3_bucket.mlflow_artifacts.id

  rule {
    id     = "transition-old-artifacts"
    status = "Enabled"

    transition {
      days          = 90
      storage_class = "STANDARD_IA"
    }
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "data_lake_bucket_name" {
  value = aws_s3_bucket.data_lake.id
}

output "data_lake_bucket_arn" {
  value = aws_s3_bucket.data_lake.arn
}

output "model_artifacts_bucket_name" {
  value = aws_s3_bucket.model_artifacts.id
}

output "model_artifacts_bucket_arn" {
  value = aws_s3_bucket.model_artifacts.arn
}

output "feature_store_bucket_name" {
  value = aws_s3_bucket.feature_store.id
}

output "feature_store_bucket_arn" {
  value = aws_s3_bucket.feature_store.arn
}

output "mlflow_artifacts_bucket_name" {
  value = aws_s3_bucket.mlflow_artifacts.id
}

output "mlflow_artifacts_bucket_arn" {
  value = aws_s3_bucket.mlflow_artifacts.arn
}
