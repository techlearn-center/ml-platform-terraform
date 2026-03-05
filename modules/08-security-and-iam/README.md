# Module 08: Security Hardening (KMS, VPC Endpoints, IAM Least Privilege)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Advanced |
| **Prerequisites** | Modules 01-07 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Implement KMS customer-managed keys with key rotation for ML data
- Configure VPC endpoints to eliminate internet traversal for AWS API calls
- Design IAM policies with least-privilege access for SageMaker, MLflow, and pipelines
- Set up S3 bucket policies that enforce encryption and restrict cross-account access
- Enable CloudTrail logging for audit compliance
- Understand security boundaries between ML platform components

---

## Concepts

### Security Architecture

```
+-------------------------------------------------------------------+
|                  ML Platform Security Layers                       |
+-------------------------------------------------------------------+
|                                                                     |
|  Layer 1: Network Security                                         |
|  +---------------------------------------------------------------+ |
|  |  VPC with private subnets | Security groups | VPC endpoints   | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  Layer 2: Identity and Access                                      |
|  +---------------------------------------------------------------+ |
|  |  IAM roles (least privilege) | Service-linked roles           | |
|  |  Role chaining | Condition keys | Permission boundaries       | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  Layer 3: Data Protection                                          |
|  +---------------------------------------------------------------+ |
|  |  KMS encryption at rest | TLS in transit | S3 bucket policies | |
|  |  RDS encryption | EBS encryption | Inter-container encryption | |
|  +---------------------------------------------------------------+ |
|                                                                     |
|  Layer 4: Audit and Compliance                                     |
|  +---------------------------------------------------------------+ |
|  |  CloudTrail | Config rules | Access Analyzer | GuardDuty      | |
|  +---------------------------------------------------------------+ |
+-------------------------------------------------------------------+
```

### IAM Role Architecture

| Role | Service | Permissions | Principle of Least Privilege |
|---|---|---|---|
| SageMaker Execution | SageMaker | S3 read/write, ECR pull, KMS, CloudWatch | Only accesses ML-specific buckets |
| MLflow Execution | ECS Tasks | ECR pull, CloudWatch Logs, Secrets Manager | Only ECS task execution needs |
| MLflow Task | ECS Tasks | S3 read/write to artifact bucket only | No access to data lake |
| Pipeline Execution | Step Functions | SageMaker jobs, S3, iam:PassRole | Can only pass SageMaker role |

---

## Hands-On Lab

### Exercise 1: Review KMS Key Configuration

The platform uses a customer-managed KMS key with automatic rotation:

```hcl
# From terraform/main.tf

resource "aws_kms_key" "sagemaker" {
  description             = "${var.project_name}-${var.environment}-sagemaker-key"
  deletion_window_in_days = 10
  enable_key_rotation     = true   # Annual automatic rotation

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootAccountFullAccess"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowSageMakerUse"
        Effect    = "Allow"
        Principal = { AWS = module.iam.sagemaker_execution_role_arn }
        Action    = [
          "kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey",
          "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:DescribeKey"
        ]
        Resource = "*"
      }
    ]
  })
}
```

**Verify KMS key:**

```bash
# Check key status and rotation
aws kms describe-key --key-id $(terraform output -raw kms_key_arn) \
  --query 'KeyMetadata.{State:KeyState,Rotation:KeyRotationStatus,Description:Description}'

aws kms get-key-rotation-status --key-id $(terraform output -raw kms_key_arn)
```

### Exercise 2: Audit IAM Policies

Review the SageMaker execution role policy for least-privilege:

```hcl
# From terraform/modules/iam/main.tf

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
          var.data_bucket_arn,       # Only specific buckets
          "${var.data_bucket_arn}/*",
          var.model_bucket_arn,
          "${var.model_bucket_arn}/*",
          var.feature_store_arn,
          "${var.feature_store_arn}/*"
        ]
      }
    ]
  })
}
```

**Check for overly permissive policies:**

```bash
# Use IAM Access Analyzer to find broad permissions
aws accessanalyzer list-findings \
  --analyzer-name ml-platform-analyzer \
  --filter '{"status": {"eq": ["ACTIVE"]}}'

# Simulate a specific action to test least privilege
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw sagemaker_role_arn) \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::some-other-bucket/secret-data.csv"
# Expected: implicitDeny (SageMaker role should NOT access arbitrary buckets)
```

### Exercise 3: S3 Bucket Policy Enforcement

Add a bucket policy that enforces encryption and blocks unencrypted uploads:

```hcl
resource "aws_s3_bucket_policy" "data_lake_security" {
  bucket = aws_s3_bucket.data_lake.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyUnencryptedObjectUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.data_lake.arn}/*"
        Condition = {
          StringNotEquals = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      },
      {
        Sid       = "RestrictToVPCEndpoint"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.data_lake.arn,
          "${aws_s3_bucket.data_lake.arn}/*"
        ]
        Condition = {
          StringNotEquals = {
            "aws:sourceVpce" = var.s3_vpc_endpoint_id
          }
        }
      }
    ]
  })
}
```

### Exercise 4: Enable CloudTrail for Audit Logging

```hcl
resource "aws_cloudtrail" "ml_platform" {
  name                       = "${var.project_name}-${var.environment}-trail"
  s3_bucket_name             = aws_s3_bucket.cloudtrail_logs.id
  include_global_service_events = true
  is_multi_region_trail      = false
  enable_log_file_validation = true

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = [
        "${aws_s3_bucket.data_lake.arn}/",
        "${aws_s3_bucket.model_artifacts.arn}/"
      ]
    }
  }

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail.arn

  tags = {
    Name = "${var.project_name}-${var.environment}-cloudtrail"
  }
}
```

### Exercise 5: Security Validation Script

```python
# scripts/security_audit.py
import boto3
from dotenv import load_dotenv
import os

load_dotenv()

def audit_s3_buckets():
    """Check all ML platform S3 buckets for security compliance."""
    s3 = boto3.client("s3")
    buckets = [
        os.getenv("DATA_LAKE_BUCKET"),
        os.getenv("MODEL_ARTIFACTS_BUCKET"),
        os.getenv("FEATURE_STORE_BUCKET"),
        os.getenv("MLFLOW_ARTIFACT_BUCKET"),
    ]

    for bucket_name in buckets:
        if not bucket_name:
            continue
        print(f"\nAuditing bucket: {bucket_name}")

        # Check encryption
        try:
            enc = s3.get_bucket_encryption(Bucket=bucket_name)
            rules = enc["ServerSideEncryptionConfiguration"]["Rules"]
            algo = rules[0]["ApplyServerSideEncryptionByDefault"]["SSEAlgorithm"]
            print(f"  Encryption: {algo} -- PASS")
        except Exception:
            print(f"  Encryption: NOT CONFIGURED -- FAIL")

        # Check versioning
        ver = s3.get_bucket_versioning(Bucket=bucket_name)
        status = ver.get("Status", "Disabled")
        print(f"  Versioning: {status} -- {'PASS' if status == 'Enabled' else 'FAIL'}")

        # Check public access block
        try:
            pab = s3.get_public_access_block(Bucket=bucket_name)
            config = pab["PublicAccessBlockConfiguration"]
            all_blocked = all([
                config["BlockPublicAcls"],
                config["IgnorePublicAcls"],
                config["BlockPublicPolicy"],
                config["RestrictPublicBuckets"],
            ])
            print(f"  Public Access Block: {'ALL BLOCKED' if all_blocked else 'PARTIAL'} -- {'PASS' if all_blocked else 'FAIL'}")
        except Exception:
            print(f"  Public Access Block: NOT CONFIGURED -- FAIL")

if __name__ == "__main__":
    audit_s3_buckets()
```

---

## Security Checklist

| Control | Implementation | Status |
|---|---|---|
| Encryption at rest (S3) | KMS CMK with bucket key | Required |
| Encryption at rest (RDS) | `storage_encrypted = true` | Required |
| Encryption at rest (EBS) | SageMaker default encrypted | Required |
| Encryption in transit | TLS for all API calls, `aws:SecureTransport` condition | Required |
| Inter-container encryption | `encrypt_inter_container_traffic = true` | Required |
| No public S3 access | `aws_s3_bucket_public_access_block` on all buckets | Required |
| VPC-only SageMaker | `direct_internet_access = "Disabled"` | Required |
| IAM least privilege | Resource-specific policies, no `*` resources | Required |
| KMS key rotation | `enable_key_rotation = true` | Required |
| Audit logging | CloudTrail with S3 data events | Required |
| No root access on notebooks | `root_access = "Disabled"` | Required |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Using `*` in IAM Resource | Over-permissive role | Specify exact ARNs for buckets, keys |
| Missing KMS key policy | SageMaker cannot encrypt | Add service principal to KMS key policy |
| No VPC endpoint for S3 | Data traverses internet | Add S3 Gateway endpoint to VPC |
| Hardcoded credentials in code | Security breach | Use IAM roles and Secrets Manager |
| CloudTrail not enabled | Cannot audit data access | Enable CloudTrail with S3 data events |

---

## Self-Check Questions

1. Why do we use customer-managed KMS keys instead of AWS-managed keys?
2. What does `enable_key_rotation = true` do and how often does it rotate?
3. How does the S3 bucket policy enforce encryption of uploaded objects?
4. Why does the pipeline execution role need `iam:PassRole` and what is the security risk?
5. What is the difference between `BlockPublicAcls` and `RestrictPublicBuckets`?

---

## You Know You Have Completed This Module When...

- [ ] KMS key is deployed with automatic rotation enabled
- [ ] All S3 buckets have encryption, versioning, and public access block
- [ ] IAM roles follow least-privilege with no `*` resource statements
- [ ] S3 bucket policy enforces KMS encryption and denies HTTP
- [ ] CloudTrail logs S3 data events for audit
- [ ] Security audit script passes all checks
- [ ] Validation script passes: `bash modules/08-security-and-iam/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: "AccessDenied" when SageMaker accesses S3**
```bash
# Check both the IAM policy AND the bucket policy
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw sagemaker_role_arn) \
  --action-names s3:GetObject \
  --resource-arns "arn:aws:s3:::$(terraform output -raw data_lake_bucket_name)/*"
```

**Issue: KMS key policy blocks access**
```bash
# List key policies and check grants
aws kms list-key-policies --key-id $(terraform output -raw kms_key_arn)
aws kms list-grants --key-id $(terraform output -raw kms_key_arn)
```

---

**Next: [Module 09 - Cost Management -->](../09-cost-management/)**
