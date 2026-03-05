# Module 05: Data Lake Setup (S3, Glue Catalog, Athena)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Intermediate |
| **Prerequisites** | Modules 01-04 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Design a multi-tier data lake architecture on S3 (raw, processed, curated)
- Deploy encrypted S3 buckets with lifecycle policies using Terraform
- Set up AWS Glue Data Catalog for schema management
- Create Glue Crawlers to automatically discover data schemas
- Query data lake contents with Amazon Athena
- Implement a feature store bucket for ML feature engineering

---

## Concepts

### Data Lake Architecture for ML

A data lake is the foundation of any ML platform. It organizes data into tiers based on processing stage:

```
+-------------------------------------------------------------------+
|                    Data Lake Architecture                           |
+-------------------------------------------------------------------+
|                                                                     |
|  S3: ml-platform-data-lake                                         |
|  +------------------+  +-------------------+  +-----------------+  |
|  |  raw/            |  |  processed/       |  |  curated/       |  |
|  |  - CSV uploads   |  |  - Cleaned data   |  |  - Feature sets |  |
|  |  - JSON events   |  |  - Transformed    |  |  - Training data|  |
|  |  - Parquet dumps |  |  - Partitioned    |  |  - Labeled data |  |
|  |  (immutable)     |  |  (idempotent)     |  |  (ML-ready)     |  |
|  +------------------+  +-------------------+  +-----------------+  |
|           |                     |                     |             |
|           v                     v                     v             |
|  +------------------+  +-------------------+  +-----------------+  |
|  |  Glue Crawler    |  |  Glue Crawler     |  |  Glue Crawler   |  |
|  |  (raw_crawler)   |  | (processed_crwlr) |  | (curated_crwlr) |  |
|  +------------------+  +-------------------+  +-----------------+  |
|           |                     |                     |             |
|           +---------------------+---------------------+             |
|                                 v                                   |
|                    +---------------------------+                    |
|                    |   Glue Data Catalog       |                    |
|                    |   (ml_platform database)  |                    |
|                    +---------------------------+                    |
|                                 |                                   |
|                                 v                                   |
|                    +---------------------------+                    |
|                    |   Amazon Athena            |                    |
|                    |   SQL queries over S3      |                    |
|                    +---------------------------+                    |
+-------------------------------------------------------------------+

  S3: ml-platform-feature-store       S3: ml-platform-model-artifacts
  +-----------------------------+     +-----------------------------+
  |  features/                  |     |  models/                    |
  |  - user_features.parquet    |     |  - xgboost/v1/model.tar.gz |
  |  - txn_features.parquet     |     |  - rf/v2/model.tar.gz      |
  +-----------------------------+     +-----------------------------+
```

### Key Terminology

| Term | Definition |
|---|---|
| **Data Lake** | Centralized repository storing raw and processed data at any scale |
| **Glue Data Catalog** | Metadata repository that stores table definitions, schemas, and partitions |
| **Glue Crawler** | Service that scans S3 and infers table schemas automatically |
| **Athena** | Serverless SQL query engine that reads directly from S3 |
| **Parquet** | Columnar storage format optimized for analytics queries |
| **Lifecycle Policy** | Automated rules for transitioning or expiring S3 objects |
| **Feature Store** | Organized collection of precomputed features for ML training and serving |

---

## Hands-On Lab

### Exercise 1: Deploy the S3 Module

**Step 1:** Review the S3 bucket configuration:

```hcl
# From terraform/modules/s3/main.tf

resource "aws_s3_bucket" "data_lake" {
  bucket = "${var.project_name}-${var.environment}-data-lake-${data.aws_caller_identity.current.account_id}"

  tags = {
    Name    = "${var.project_name}-${var.environment}-data-lake"
    Purpose = "data-lake"
  }
}

# Versioning for data lineage
resource "aws_s3_bucket_versioning" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

# KMS encryption at rest
resource "aws_s3_bucket_server_side_encryption_configuration" "data_lake" {
  bucket = aws_s3_bucket.data_lake.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true   # Reduces KMS API costs
  }
}

# Block all public access
resource "aws_s3_bucket_public_access_block" "data_lake" {
  bucket                  = aws_s3_bucket.data_lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

**Step 2:** Deploy:

```bash
cd terraform/
terraform apply -target=module.s3
```

**Step 3:** Verify buckets exist:

```bash
aws s3 ls | grep ml-platform
```

### Exercise 2: Configure Lifecycle Policies

Lifecycle policies automatically transition old data to cheaper storage:

```hcl
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
      storage_class = "STANDARD_IA"    # ~40% cheaper after 30 days
    }
    transition {
      days          = 90
      storage_class = "GLACIER"         # ~80% cheaper after 90 days
    }
  }

  rule {
    id     = "expire-temp-data"
    status = "Enabled"
    filter {
      prefix = "tmp/"
    }
    expiration {
      days = 7                          # Auto-delete temp files after 7 days
    }
  }
}
```

**Storage cost comparison:**

| Storage Class | Cost per GB/month | Use Case |
|---|---|---|
| S3 Standard | $0.023 | Active data (< 30 days old) |
| S3 Standard-IA | $0.0125 | Infrequent access (30-90 days) |
| S3 Glacier | $0.004 | Archive (90+ days) |
| S3 Glacier Deep | $0.00099 | Long-term compliance (years) |

### Exercise 3: Set Up Glue Data Catalog

Create Terraform resources for the Glue Data Catalog:

```hcl
# Add to your Terraform configuration (lab exercise)

resource "aws_glue_catalog_database" "ml_platform" {
  name        = "${var.project_name}_${var.environment}"
  description = "Data catalog for ML platform data lake"
}

resource "aws_iam_role" "glue_crawler" {
  name = "${var.project_name}-${var.environment}-glue-crawler"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "glue.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "glue_service" {
  role       = aws_iam_role.glue_crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

resource "aws_glue_crawler" "raw_data" {
  database_name = aws_glue_catalog_database.ml_platform.name
  name          = "${var.project_name}-${var.environment}-raw-crawler"
  role          = aws_iam_role.glue_crawler.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.id}/raw/"
  }

  schedule = "cron(0 */6 * * ? *)"  # Run every 6 hours

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }
}

resource "aws_glue_crawler" "processed_data" {
  database_name = aws_glue_catalog_database.ml_platform.name
  name          = "${var.project_name}-${var.environment}-processed-crawler"
  role          = aws_iam_role.glue_crawler.arn

  s3_target {
    path = "s3://${aws_s3_bucket.data_lake.id}/processed/"
  }

  schedule = "cron(0 */6 * * ? *)"
}
```

### Exercise 4: Query with Athena

```python
# scripts/query_data_lake.py
import boto3
import time
from dotenv import load_dotenv
import os

load_dotenv()

athena = boto3.client("athena")
bucket = os.getenv("DATA_LAKE_BUCKET")

# Create Athena workgroup with output location
query = """
SELECT
    feature_name,
    COUNT(*) as record_count,
    AVG(feature_value) as avg_value,
    STDDEV(feature_value) as stddev_value
FROM ml_platform_dev.processed_features
WHERE partition_date >= '2024-01-01'
GROUP BY feature_name
ORDER BY record_count DESC
LIMIT 20
"""

# Execute query
response = athena.start_query_execution(
    QueryString=query,
    QueryExecutionContext={"Database": "ml_platform_dev"},
    ResultConfiguration={
        "OutputLocation": f"s3://{bucket}/athena-results/"
    },
)

query_id = response["QueryExecutionId"]
print(f"Query ID: {query_id}")

# Wait for completion
while True:
    status = athena.get_query_execution(QueryExecutionId=query_id)
    state = status["QueryExecution"]["Status"]["State"]
    if state in ("SUCCEEDED", "FAILED", "CANCELLED"):
        break
    time.sleep(2)

if state == "SUCCEEDED":
    results = athena.get_query_results(QueryExecutionId=query_id)
    for row in results["ResultSet"]["Rows"]:
        print([col.get("VarCharValue", "") for col in row["Data"]])
else:
    print(f"Query failed: {status['QueryExecution']['Status'].get('StateChangeReason')}")
```

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Missing bucket policy for public block | Data leak risk | Always set `aws_s3_bucket_public_access_block` |
| No versioning on data lake | Cannot recover deleted data | Enable versioning on all ML buckets |
| Storing everything in S3 Standard | High storage costs | Use lifecycle policies for older data |
| No partition strategy | Slow Athena queries | Partition by date/region in S3 key structure |
| Glue crawler runs too frequently | High Glue costs | Schedule crawlers based on data arrival frequency |

---

## Self-Check Questions

1. What are the three tiers of a data lake and what data goes in each?
2. Why do we use KMS encryption with bucket keys instead of SSE-S3?
3. How do S3 lifecycle policies reduce storage costs for ML data?
4. What is the role of a Glue Crawler in the data catalog workflow?
5. Why do we use Parquet format instead of CSV for processed data?

---

## You Know You Have Completed This Module When...

- [ ] Four S3 buckets deployed (data lake, model artifacts, feature store, MLflow artifacts)
- [ ] All buckets have versioning, encryption, and public access block enabled
- [ ] Lifecycle policies are configured for cost optimization
- [ ] Glue Data Catalog database and crawlers are created
- [ ] Athena query runs successfully against data lake
- [ ] Validation script passes: `bash modules/05-airflow-infrastructure/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: Athena query fails with "access denied"**
```bash
# Verify the Athena workgroup has access to the S3 output location
aws s3 ls s3://${DATA_LAKE_BUCKET}/athena-results/
```

**Issue: Glue Crawler finds no tables**
```bash
# Verify data exists in the S3 path
aws s3 ls s3://${DATA_LAKE_BUCKET}/raw/ --recursive | head -5

# Check crawler status
aws glue get-crawler --name ml-platform-dev-raw-crawler \
  --query '{State:State,LastCrawl:LastCrawl}'
```

**Issue: KMS encryption errors**
```bash
# Verify the KMS key policy allows the service
aws kms describe-key --key-id $(terraform output -raw kms_key_arn) \
  --query 'KeyMetadata.{KeyState:KeyState,Enabled:Enabled}'
```

---

**Next: [Module 06 - Pipeline Orchestration -->](../06-data-storage/)**
