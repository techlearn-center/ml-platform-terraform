# Module 01: ML Platform Architecture Fundamentals

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Beginner |
| **Prerequisites** | AWS account, Terraform >= 1.5 installed, basic CLI knowledge |

---

## Learning Objectives

By the end of this module, you will be able to:

- Understand the architecture of a production ML platform on AWS
- Identify the core components: compute, storage, orchestration, experiment tracking, and serving
- Map Terraform modules to platform components
- Set up the Terraform project structure and remote backend
- Configure AWS credentials and provider settings

---

## Concepts

### What Is an ML Platform?

An ML platform is the integrated set of infrastructure and services that supports the full machine learning lifecycle: data ingestion, feature engineering, model training, experiment tracking, model registry, deployment, monitoring, and retraining.

```
+-------------------------------------------------------------------+
|                        ML Platform Architecture                    |
+-------------------------------------------------------------------+
|                                                                    |
|   +-----------+     +------------+     +-----------+               |
|   |  Data Lake|     |  Feature   |     |  Model    |               |
|   |  (S3)     |---->|  Store     |---->|  Training |               |
|   |           |     |  (S3)      |     | (SageMaker)|              |
|   +-----------+     +------------+     +-----------+               |
|                                             |                      |
|                                             v                      |
|   +-----------+     +------------+     +-----------+               |
|   | Monitoring|     |  Model     |     | Experiment|               |
|   | (CW/Grafana)<---|  Serving   |     | Tracking  |               |
|   |           |     | (SageMaker)|     | (MLflow)  |               |
|   +-----------+     +------------+     +-----------+               |
|                                                                    |
|   +-----------+     +------------+     +-----------+               |
|   |  IAM &    |     |  VPC &     |     | Pipeline  |               |
|   |  Security |     |  Networking|     | Orchestr. |               |
|   |  (IAM/KMS)|     | (VPC)      |     |(Step Fn)  |               |
|   +-----------+     +------------+     +-----------+               |
+-------------------------------------------------------------------+
```

### Platform Components and Terraform Modules

| Component | AWS Service | Terraform Module | Purpose |
|---|---|---|---|
| Networking | VPC, Subnets, NAT | `terraform/modules/vpc` | Isolate ML workloads in private subnets |
| Compute | SageMaker Studio | `terraform/modules/sagemaker` | Interactive development and training |
| Experiment Tracking | MLflow on ECS | `terraform/modules/mlflow` | Track parameters, metrics, artifacts |
| Storage | S3 Buckets | `terraform/modules/s3` | Data lake, model artifacts, features |
| Security | IAM Roles, KMS | `terraform/modules/iam` | Least-privilege access, encryption |

### Key Terminology

| Term | Definition |
|---|---|
| **SageMaker Studio** | Fully managed IDE for ML providing notebooks, debugger, and model monitor |
| **MLflow** | Open-source platform for experiment tracking, model registry, and deployment |
| **Feature Store** | Centralized repository of curated features for training and inference |
| **Model Registry** | Versioned catalog of trained models with approval workflows |
| **Data Lake** | Centralized repository for structured and unstructured data at scale |
| **IaC (Infrastructure as Code)** | Managing infrastructure through code instead of manual processes |

---

## Hands-On Lab

### Prerequisites Check

```bash
# Verify Terraform is installed
terraform --version
# Expected: Terraform v1.5.0 or later

# Verify AWS CLI is configured
aws sts get-caller-identity
# Expected: JSON with your Account, UserId, Arn

# Verify Python (for helper scripts)
python3 --version
pip install -r requirements.txt
```

### Exercise 1: Set Up the Terraform Backend

Before deploying any infrastructure, we need a remote backend to store Terraform state.

**Step 1:** Create the S3 bucket and DynamoDB table for state management:

```bash
# Create the S3 bucket for Terraform state
aws s3api create-bucket \
  --bucket ml-platform-tfstate \
  --region us-east-1

# Enable versioning on the state bucket
aws s3api put-bucket-versioning \
  --bucket ml-platform-tfstate \
  --versioning-configuration Status=Enabled

# Enable server-side encryption
aws s3api put-bucket-encryption \
  --bucket ml-platform-tfstate \
  --server-side-encryption-configuration '{
    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
  }'

# Block public access to the state bucket
aws s3api put-public-access-block \
  --bucket ml-platform-tfstate \
  --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Create DynamoDB table for state locking
aws dynamodb create-table \
  --table-name ml-platform-tflock \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

**Step 2:** Initialize Terraform with the remote backend:

```bash
cd terraform/
terraform init
```

**What you should see:** Terraform downloads providers and initializes the backend.

### Exercise 2: Review the Module Structure

**Step 1:** Explore the project layout:

```bash
tree terraform/
# terraform/
# ├── main.tf            # Root module - calls all sub-modules
# ├── variables.tf       # Input variables for the platform
# ├── outputs.tf         # Output values (endpoints, ARNs, bucket names)
# └── modules/
#     ├── vpc/main.tf     # VPC, subnets, NAT, VPC endpoints
#     ├── sagemaker/main.tf # Studio domain, notebooks, model registry
#     ├── mlflow/main.tf  # ECS Fargate, RDS, ALB for MLflow
#     ├── s3/main.tf      # Data lake, model artifacts, feature store
#     └── iam/main.tf     # IAM roles and policies
```

**Step 2:** Read the root `main.tf` and identify how modules reference each other:

```hcl
# Example: the SageMaker module depends on VPC and IAM outputs
module "sagemaker" {
  source = "./modules/sagemaker"

  vpc_id                      = module.vpc.vpc_id
  private_subnet_ids          = module.vpc.private_subnet_ids
  sagemaker_execution_role_arn = module.iam.sagemaker_execution_role_arn
  # ...
}
```

**Step 3:** Run `terraform validate` to confirm the configuration is syntactically valid:

```bash
terraform validate
```

### Exercise 3: Generate and Review the Plan

```bash
# Create a tfvars file for your environment
cat > terraform.tfvars << 'EOF'
aws_region    = "us-east-1"
project_name  = "ml-platform"
environment   = "dev"
EOF

# Generate a plan (no resources will be created)
terraform plan -out=tfplan

# Review what Terraform will create
terraform show tfplan
```

---

## Architecture Decision Records

| Decision | Choice | Rationale |
|---|---|---|
| VPC Mode | Private subnets with NAT | ML data stays in private network; NAT provides outbound access |
| SageMaker Mode | VPC-only | No direct internet access to notebooks for security |
| MLflow Hosting | ECS Fargate | Serverless containers avoid managing EC2; auto-scales |
| State Backend | S3 + DynamoDB | Industry standard; supports locking and versioning |
| Encryption | KMS CMK | Customer-managed keys for compliance; key rotation enabled |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Missing AWS credentials | `NoCredentialProviders` error | Run `aws configure` or set `AWS_PROFILE` |
| Wrong region in backend config | State bucket not found | Ensure `TF_STATE_REGION` matches the bucket's region |
| Terraform version mismatch | `required_version` constraint fails | Upgrade Terraform to >= 1.5.0 |
| Not initializing before plan | Provider not installed | Always run `terraform init` first |

---

## Self-Check Questions

1. What are the five core components of this ML platform and which AWS services implement them?
2. Why do we use a remote backend for Terraform state instead of local state?
3. What is the purpose of the DynamoDB lock table?
4. How does module composition work in Terraform -- how does the SageMaker module get the VPC ID?
5. Why is VPC-only mode important for SageMaker in a production environment?

---

## You Know You Have Completed This Module When...

- [ ] Terraform backend (S3 + DynamoDB) is created
- [ ] `terraform init` succeeds against the remote backend
- [ ] `terraform validate` passes
- [ ] `terraform plan` generates a valid plan
- [ ] You can draw the architecture diagram from memory
- [ ] Validation script passes: `bash modules/01-ml-platform-architecture/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: `terraform init` fails with "access denied"**
```bash
# Verify your AWS credentials
aws sts get-caller-identity

# Check the S3 bucket exists
aws s3 ls s3://ml-platform-tfstate/
```

**Issue: `terraform plan` shows unexpected changes**
```bash
# Compare state with reality
terraform refresh

# Check for drift
terraform plan -detailed-exitcode
```

---

**Next: [Module 02 - VPC and Networking for ML -->](../02-vpc-and-networking/)**
