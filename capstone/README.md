# Capstone Project: Production ML Platform on AWS with Terraform

## Overview

This capstone project combines everything you learned across all 10 modules into a single, production-grade ML platform deployment. You will deploy, configure, validate, and document a complete ML infrastructure on AWS using Terraform. This is the project you will showcase to hiring managers.

---

## Architecture Diagram

```
+===========================================================================+
|                    Production ML Platform on AWS                          |
|                    Managed with Terraform                                  |
+===========================================================================+
|                                                                            |
|  +--- VPC: 10.0.0.0/16 (Module 02) -----------------------------------+  |
|  |                                                                      |  |
|  |  +--- Public Subnets ---+    +--- Public Subnets ---+               |  |
|  |  | 10.0.0.0/24 (AZ-a)  |    | 10.0.1.0/24 (AZ-b)  |               |  |
|  |  | [NAT Gateway]       |    | [NAT Gateway*]       |               |  |
|  |  | [ALB - MLflow]      |    |                       |               |  |
|  |  +----------------------+    +-----------------------+               |  |
|  |          |                           |                               |  |
|  |  +--- Private Subnets (ML Workloads) ---------------------------+   |  |
|  |  | 10.0.10.0/24 (AZ-a)         | 10.0.11.0/24 (AZ-b)           |   |  |
|  |  |                              |                                |   |  |
|  |  |  +------------------------+  |  +-------------------------+  |   |  |
|  |  |  | SageMaker Studio       |  |  | ECS Fargate             |  |   |  |
|  |  |  | (Module 03)            |  |  | MLflow Server           |  |   |  |
|  |  |  | - Data Scientist       |  |  | (Module 04)             |  |   |  |
|  |  |  | - ML Engineer          |  |  | - Tracking API          |  |   |  |
|  |  |  | - Notebook Instance    |  |  | - Artifact Proxy        |  |   |  |
|  |  |  +------------------------+  |  +-------------------------+  |   |  |
|  |  |                              |                                |   |  |
|  |  |  +------------------------+  |  +-------------------------+  |   |  |
|  |  |  | SageMaker Endpoints    |  |  | RDS PostgreSQL          |  |   |  |
|  |  |  | (Module 03)            |  |  | (Module 04)             |  |   |  |
|  |  |  | - Model Serving        |  |  | - MLflow Metadata       |  |   |  |
|  |  |  | - Auto-scaling         |  |  | - Encrypted Storage     |  |   |  |
|  |  |  +------------------------+  |  +-------------------------+  |   |  |
|  |  +--------------------------------------------------------------+   |  |
|  |                                                                      |  |
|  |  +--- VPC Endpoints (Module 02) --------------------------------+   |  |
|  |  | S3 (Gateway) | ECR API | ECR DKR | SageMaker | CloudWatch    |   |  |
|  |  +--------------------------------------------------------------+   |  |
|  +----------------------------------------------------------------------+  |
|                                                                            |
|  +--- S3 Storage Layer (Module 05) ------------------------------------+  |
|  |                                                                      |  |
|  |  +----------------+ +------------------+ +-------------------+      |  |
|  |  | Data Lake      | | Model Artifacts  | | Feature Store     |      |  |
|  |  | raw/           | | models/          | | features/         |      |  |
|  |  | processed/     | | checkpoints/     | | user_features/    |      |  |
|  |  | curated/       | | training-output/ | | txn_features/     |      |  |
|  |  +----------------+ +------------------+ +-------------------+      |  |
|  |                                                                      |  |
|  |  +----------------+ +------------------------------------------+   |  |
|  |  | MLflow Artifacts| | Glue Data Catalog + Athena Queries      |   |  |
|  |  | experiments/   | | (Crawlers discover schemas automatically)|   |  |
|  |  | models/        | +------------------------------------------+   |  |
|  |  +----------------+                                                 |  |
|  +----------------------------------------------------------------------+  |
|                                                                            |
|  +--- Pipeline Orchestration (Module 06) ------------------------------+  |
|  |                                                                      |  |
|  |  Step Functions State Machine:                                       |  |
|  |  [Ingest] -> [Preprocess] -> [Train] -> [Evaluate] -> [Register]   |  |
|  |                                                    |                 |  |
|  |                                              {accuracy > 0.9?}      |  |
|  |                                              Yes -> [Deploy]         |  |
|  |                                              No  -> [Alert SNS]     |  |
|  |                                                                      |  |
|  |  EventBridge: Weekly scheduled retraining                            |  |
|  +----------------------------------------------------------------------+  |
|                                                                            |
|  +--- Monitoring & Security (Modules 07-08) ---------------------------+  |
|  |                                                                      |  |
|  |  CloudWatch Dashboard    | SNS Alerts      | AWS Budgets            |  |
|  |  - Endpoint latency      | - 5XX errors    | - 80% threshold        |  |
|  |  - ECS CPU/Memory        | - High latency  | - 100% forecasted      |  |
|  |  - RDS storage/CPU       | - Low storage   |                        |  |
|  |                                                                      |  |
|  |  KMS Encryption (CMK)    | IAM Least Privilege | CloudTrail Audit   |  |
|  |  - S3 bucket keys        | - Role per service  | - S3 data events   |  |
|  |  - RDS encrypted         | - No wildcard ARN   | - Management events |  |
|  |  - SageMaker EFS         | - Condition keys    |                     |  |
|  +----------------------------------------------------------------------+  |
|                                                                            |
|  +--- Multi-Environment (Module 10) -----------------------------------+  |
|  |                                                                      |  |
|  |  dev (10.0.0.0/16)  ->  staging (10.1.0.0/16)  ->  prod (10.2.0.0) |  |
|  |  Single NAT             Single NAT                 3 NAT GWs (HA)  |  |
|  |  1 MLflow task           1 MLflow task              2 MLflow tasks   |  |
|  |  Single-AZ RDS           Single-AZ RDS              Multi-AZ RDS    |  |
|  |                                                                      |  |
|  |  Separate Terraform state per environment                            |  |
|  |  CI/CD: GitHub Actions (plan on PR, apply on merge)                 |  |
|  +----------------------------------------------------------------------+  |
+============================================================================+
```

---

## The Challenge

Build the complete ML platform depicted in the architecture diagram above, using Terraform to manage all infrastructure. Your deployment must demonstrate proficiency in:

1. **Networking** (Module 02): VPC with public/private subnets, NAT, VPC endpoints
2. **Compute** (Module 03): SageMaker Studio domain, notebook instances, model registry
3. **Experiment Tracking** (Module 04): MLflow on ECS Fargate with RDS backend
4. **Storage** (Module 05): S3 data lake with lifecycle policies, Glue catalog
5. **Orchestration** (Module 06): Step Functions pipeline for training workflow
6. **Monitoring** (Module 07): CloudWatch dashboards, alarms, budget alerts
7. **Security** (Module 08): KMS encryption, IAM least privilege, audit logging
8. **Cost Management** (Module 09): Spot training, auto-stop, environment-aware sizing
9. **Multi-Environment** (Module 10): Dev/staging/prod with separate state files

---

## Acceptance Criteria

### Must Have (Required for Completion)

- [ ] **Terraform Deploys Successfully**: `terraform apply` completes without errors for the dev environment
- [ ] **VPC Created**: VPC with public/private subnets across 2+ AZs, NAT gateway operational
- [ ] **VPC Endpoints Active**: S3 gateway endpoint and at least 2 interface endpoints deployed
- [ ] **SageMaker Studio Domain**: Domain created in VPC-only mode with IAM auth
- [ ] **SageMaker User Profiles**: At least 2 user profiles (data-scientist, ml-engineer)
- [ ] **SageMaker Notebook**: Notebook instance with auto-stop lifecycle and KMS encryption
- [ ] **Model Registry**: SageMaker Model Package Group created
- [ ] **MLflow Tracking Server**: ECS Fargate service running MLflow, accessible via ALB
- [ ] **MLflow Database**: RDS PostgreSQL with encrypted storage and automated backups
- [ ] **S3 Buckets**: 4 buckets (data lake, model artifacts, feature store, MLflow artifacts)
- [ ] **S3 Security**: All buckets have versioning, KMS encryption, and public access block
- [ ] **S3 Lifecycle**: Raw data transitions to IA after 30 days, Glacier after 90 days
- [ ] **IAM Roles**: Separate roles for SageMaker, MLflow execution, MLflow task, pipeline
- [ ] **IAM Least Privilege**: No `*` in Resource fields; all roles scoped to specific ARNs
- [ ] **KMS Key**: Customer-managed key with rotation enabled
- [ ] **CloudWatch Alarms**: At least 3 alarms (endpoint latency, ECS CPU, RDS storage)
- [ ] **Budget Alert**: AWS Budget configured with email notification
- [ ] **Security Groups**: Separate SGs for SageMaker, MLflow, RDS, VPC endpoints
- [ ] **Environment Variables**: tfvars files for dev, staging, and prod
- [ ] **Terraform Outputs**: Endpoints, bucket names, role ARNs exported as outputs

### Nice to Have (Bonus Points)

- [ ] **MLflow Experiment**: Python script logs an experiment with metrics and model artifact
- [ ] **Training Job**: SageMaker training job runs with spot instances and checkpoints
- [ ] **Step Functions Pipeline**: State machine deployed with preprocess/train/evaluate steps
- [ ] **CI/CD Pipeline**: GitHub Actions workflow for terraform plan/apply
- [ ] **CloudWatch Dashboard**: Visual dashboard with SageMaker, ECS, and RDS widgets
- [ ] **Model Promotion**: Script to promote models between dev/staging/prod
- [ ] **CloudTrail**: Audit logging for S3 data events
- [ ] **Glue Data Catalog**: Database and crawlers for data lake schema discovery
- [ ] **Athena Queries**: SQL queries running against data lake via Athena
- [ ] **Cost Report**: Python script showing costs grouped by service and project tag

---

## Getting Started

```bash
# 1. Clone the repo and install dependencies
git clone https://github.com/techlearn-center/ml-platform-terraform.git
cd ml-platform-terraform
pip install -r requirements.txt
cp .env.example .env
# Edit .env with your AWS account details

# 2. Set up the Terraform backend
aws s3api create-bucket --bucket ml-platform-tfstate --region us-east-1
aws dynamodb create-table --table-name ml-platform-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST

# 3. Initialize and deploy
cd terraform
terraform init
terraform plan -var-file=environments/dev.tfvars -out=tfplan
terraform apply tfplan

# 4. Verify deployment
terraform output
python scripts/security_audit.py

# 5. Validate your work
bash capstone/validation/validate.sh
```

---

## Evaluation Criteria

| Criteria | Weight | Description |
|---|---|---|
| **Functionality** | 30% | All Must Have acceptance criteria pass |
| **Architecture** | 20% | Clean module composition, proper dependencies between modules |
| **Security** | 15% | KMS encryption, IAM least privilege, no public access, VPC-only |
| **Cost Awareness** | 15% | Environment-specific sizing, spot training, lifecycle policies |
| **Automation** | 10% | CI/CD pipeline, scheduled pipelines, auto-stop/auto-scale |
| **Code Quality** | 10% | Consistent naming, proper tagging, validated variables |

---

## Deliverables

When you complete this capstone, prepare the following:

1. **Terraform code** in the `capstone/solution/` directory (or use the root `terraform/` directory)
2. **Python scripts** for experiment logging, training jobs, model promotion, and cost reporting
3. **Environment tfvars** for dev, staging, and prod
4. **Screenshots** of:
   - SageMaker Studio domain in the AWS console
   - MLflow UI showing a logged experiment
   - CloudWatch dashboard with metrics
   - `terraform output` showing all endpoints and ARNs
5. **Architecture decision document** explaining your choices for:
   - Why ECS Fargate for MLflow (vs. EC2, vs. EKS)
   - Why Step Functions for orchestration (vs. Airflow, vs. SageMaker Pipelines)
   - How you handle secrets (Secrets Manager vs. Parameter Store)
   - Your cost optimization strategy

---

## Showcasing to Hiring Managers

When you complete this capstone:

1. **Fork this repo** to your personal GitHub
2. **Add your solution** with detailed commit messages
3. **Update the README** with your architecture decisions and screenshots
4. **Record a 5-minute demo video** walking through the deployment
5. **Reference it on your resume** as: "Designed and deployed production ML platform on AWS using Terraform (SageMaker, MLflow, ECS, RDS, VPC)"
6. **Be ready to discuss**: Security choices, cost trade-offs, multi-environment strategy

See [docs/portfolio-guide.md](../docs/portfolio-guide.md) for detailed guidance.
