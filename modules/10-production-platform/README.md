# Module 10: Multi-Environment Deployment (Dev/Staging/Prod with Terraform Workspaces)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Advanced |
| **Prerequisites** | Modules 01-09 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Deploy the ML platform across dev, staging, and prod environments
- Use Terraform workspaces to manage multiple environments from one codebase
- Configure environment-specific variable files (tfvars)
- Implement a CI/CD pipeline for Terraform with GitHub Actions
- Understand blue/green deployment for SageMaker endpoints
- Set up cross-environment promotion for model artifacts

---

## Concepts

### Multi-Environment Strategy

```
+-------------------------------------------------------------------+
|              Multi-Environment Architecture                        |
+-------------------------------------------------------------------+
|                                                                     |
|  +--- dev ---+     +--- staging ---+     +--- prod ---+            |
|  | VPC       |     | VPC           |     | VPC        |            |
|  | 10.0.0/16 |     | 10.1.0.0/16  |     | 10.2.0.0/16|            |
|  |           |     |               |     |            |            |
|  | SageMaker |     | SageMaker     |     | SageMaker  |            |
|  | 1 notebook|     | 1 notebook    |     | Studio     |            |
|  |           |     |               |     |            |            |
|  | MLflow    |     | MLflow        |     | MLflow     |            |
|  | 1 task    |     | 1 task        |     | 2 tasks    |            |
|  |           |     |               |     |            |            |
|  | RDS       |     | RDS           |     | RDS        |            |
|  | single-AZ |     | single-AZ     |     | multi-AZ   |            |
|  |           |     |               |     |            |            |
|  | 1 NAT GW  |     | 1 NAT GW     |     | 3 NAT GWs |            |
|  +-----------+     +---------------+     +------------+            |
|       |                   |                    |                    |
|       v                   v                    v                    |
|  S3: dev-data-lake   S3: stg-data-lake   S3: prod-data-lake       |
|  S3: dev-models      S3: stg-models      S3: prod-models          |
+-------------------------------------------------------------------+
|                                                                     |
|  Model Promotion Flow:                                              |
|  [Train in dev] --> [Validate in staging] --> [Deploy to prod]     |
|                                                                     |
|  Terraform State:                                                   |
|  s3://tfstate/dev/terraform.tfstate                                |
|  s3://tfstate/staging/terraform.tfstate                            |
|  s3://tfstate/prod/terraform.tfstate                               |
+-------------------------------------------------------------------+
```

### Terraform Workspaces vs. Directory-Based Environments

| Approach | Pros | Cons |
|---|---|---|
| **Workspaces** | Single codebase, easy switching | All envs share same backend config |
| **Directory-based** | Complete isolation, independent state | Code duplication, drift risk |
| **Recommended: tfvars** | Single codebase + separate state per env | Slightly more CLI flags |

We use the **tfvars approach** -- one codebase with environment-specific variable files and separate state keys.

---

## Hands-On Lab

### Exercise 1: Create Environment Variable Files

```bash
# terraform/environments/dev.tfvars
cat > terraform/environments/dev.tfvars << 'EOF'
aws_region         = "us-east-1"
project_name       = "ml-platform"
environment        = "dev"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

# Smaller instances for dev
notebook_instance_type   = "ml.t3.medium"
training_instance_type   = "ml.m5.xlarge"
endpoint_instance_type   = "ml.m5.large"
mlflow_db_instance_class = "db.t3.small"
mlflow_container_cpu     = 512
mlflow_container_memory  = 1024

# Lower budget for dev
budget_limit_monthly = 300
alert_email          = "ml-dev@example.com"
EOF

# terraform/environments/staging.tfvars
cat > terraform/environments/staging.tfvars << 'EOF'
aws_region         = "us-east-1"
project_name       = "ml-platform"
environment        = "staging"
vpc_cidr           = "10.1.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b"]

notebook_instance_type   = "ml.t3.medium"
training_instance_type   = "ml.m5.xlarge"
endpoint_instance_type   = "ml.m5.large"
mlflow_db_instance_class = "db.t3.medium"
mlflow_container_cpu     = 1024
mlflow_container_memory  = 2048

budget_limit_monthly = 500
alert_email          = "ml-staging@example.com"
EOF

# terraform/environments/prod.tfvars
cat > terraform/environments/prod.tfvars << 'EOF'
aws_region         = "us-east-1"
project_name       = "ml-platform"
environment        = "prod"
vpc_cidr           = "10.2.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

notebook_instance_type   = "ml.t3.large"
training_instance_type   = "ml.m5.2xlarge"
endpoint_instance_type   = "ml.m5.xlarge"
mlflow_db_instance_class = "db.r6g.large"
mlflow_container_cpu     = 2048
mlflow_container_memory  = 4096

budget_limit_monthly = 2000
alert_email          = "ml-prod@example.com"
EOF
```

### Exercise 2: Deploy Per-Environment

```bash
# Deploy dev environment
cd terraform/

terraform init \
  -backend-config="key=ml-platform/dev/terraform.tfstate"

terraform plan \
  -var-file=environments/dev.tfvars \
  -out=dev.tfplan

terraform apply dev.tfplan

# Deploy staging environment (separate state)
terraform init -reconfigure \
  -backend-config="key=ml-platform/staging/terraform.tfstate"

terraform plan \
  -var-file=environments/staging.tfvars \
  -out=staging.tfplan

terraform apply staging.tfplan

# Deploy prod environment (separate state)
terraform init -reconfigure \
  -backend-config="key=ml-platform/prod/terraform.tfstate"

terraform plan \
  -var-file=environments/prod.tfvars \
  -out=prod.tfplan

terraform apply prod.tfplan
```

### Exercise 3: CI/CD with GitHub Actions

```yaml
# .github/workflows/terraform.yml
name: Terraform ML Platform

on:
  push:
    branches: [main]
    paths: ['terraform/**']
  pull_request:
    branches: [main]
    paths: ['terraform/**']

env:
  TF_VERSION: '1.5.7'
  AWS_REGION: 'us-east-1'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - name: Terraform Format Check
        run: terraform fmt -check -recursive
        working-directory: terraform

      - name: Terraform Init
        run: terraform init -backend=false
        working-directory: terraform

      - name: Terraform Validate
        run: terraform validate
        working-directory: terraform

  plan-dev:
    needs: validate
    runs-on: ubuntu-latest
    if: github.event_name == 'pull_request'
    permissions:
      id-token: write
      contents: read
      pull-requests: write
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init -backend-config="key=ml-platform/dev/terraform.tfstate"
        working-directory: terraform

      - name: Terraform Plan
        id: plan
        run: terraform plan -var-file=environments/dev.tfvars -no-color
        working-directory: terraform

      - name: Comment PR with Plan
        uses: actions/github-script@v7
        with:
          script: |
            const output = `#### Terraform Plan
            \`\`\`
            ${{ steps.plan.outputs.stdout }}
            \`\`\``;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            })

  deploy-dev:
    needs: validate
    runs-on: ubuntu-latest
    if: github.ref == 'refs/heads/main' && github.event_name == 'push'
    environment: dev
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ env.TF_VERSION }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Terraform Init
        run: terraform init -backend-config="key=ml-platform/dev/terraform.tfstate"
        working-directory: terraform

      - name: Terraform Apply
        run: terraform apply -var-file=environments/dev.tfvars -auto-approve
        working-directory: terraform
```

### Exercise 4: Model Promotion Across Environments

```python
# scripts/promote_model.py
"""
Promote a model from one environment to another by copying
the artifact and registering it in the target environment's
model registry.
"""
import boto3
import argparse
from dotenv import load_dotenv
import os

load_dotenv()


def promote_model(model_package_arn, source_env, target_env):
    """Copy model artifact and register in target environment."""
    sm_client = boto3.client("sagemaker")
    s3_client = boto3.client("s3")

    # Get the source model package details
    source_pkg = sm_client.describe_model_package(
        ModelPackageName=model_package_arn
    )

    source_model_url = source_pkg["InferenceSpecification"]["Containers"][0]["ModelDataUrl"]
    source_bucket = source_model_url.split("/")[2]
    source_key = "/".join(source_model_url.split("/")[3:])

    # Copy artifact to target environment bucket
    target_bucket = f"ml-platform-{target_env}-model-artifacts-{os.getenv('AWS_ACCOUNT_ID')}"
    target_key = source_key

    print(f"Copying model from {source_bucket}/{source_key} to {target_bucket}/{target_key}")
    s3_client.copy_object(
        Bucket=target_bucket,
        Key=target_key,
        CopySource={"Bucket": source_bucket, "Key": source_key},
    )

    # Register in target environment model registry
    target_model_url = f"s3://{target_bucket}/{target_key}"
    target_group = f"ml-platform-{target_env}-models"

    response = sm_client.create_model_package(
        ModelPackageGroupName=target_group,
        ModelPackageDescription=f"Promoted from {source_env}: {source_pkg.get('ModelPackageDescription', '')}",
        InferenceSpecification={
            "Containers": [{
                "Image": source_pkg["InferenceSpecification"]["Containers"][0]["Image"],
                "ModelDataUrl": target_model_url,
            }],
            "SupportedContentTypes": source_pkg["InferenceSpecification"]["SupportedContentTypes"],
            "SupportedResponseMIMETypes": source_pkg["InferenceSpecification"]["SupportedResponseMIMETypes"],
        },
        ModelApprovalStatus="PendingManualApproval",
    )

    print(f"Model registered in {target_env}: {response['ModelPackageArn']}")
    return response["ModelPackageArn"]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Promote ML model across environments")
    parser.add_argument("--model-arn", required=True, help="Source model package ARN")
    parser.add_argument("--source-env", required=True, choices=["dev", "staging", "prod"])
    parser.add_argument("--target-env", required=True, choices=["dev", "staging", "prod"])
    args = parser.parse_args()

    promote_model(args.model_arn, args.source_env, args.target_env)
```

---

## Environment Differences Summary

| Setting | Dev | Staging | Prod |
|---|---|---|---|
| VPC CIDR | 10.0.0.0/16 | 10.1.0.0/16 | 10.2.0.0/16 |
| Availability Zones | 2 | 2 | 3 |
| NAT Gateways | 1 | 1 | 3 |
| SageMaker Notebook | ml.t3.medium | ml.t3.medium | ml.t3.large |
| MLflow Tasks | 1 | 1 | 2 |
| RDS Multi-AZ | No | No | Yes |
| RDS Instance | db.t3.small | db.t3.medium | db.r6g.large |
| Deletion Protection | No | No | Yes |
| Final Snapshot | Skip | Skip | Required |
| Budget Limit | $300 | $500 | $2000 |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Same state key for all envs | Environments overwrite each other | Use different `-backend-config="key=..."` |
| Same VPC CIDR | Cannot peer VPCs | Use non-overlapping CIDRs per env |
| Missing environment variable | Resources named incorrectly | Always pass `-var-file=environments/$ENV.tfvars` |
| Auto-approve in prod CI/CD | Accidental destructive changes | Require manual approval step for prod |
| No model promotion workflow | Models retrained from scratch per env | Copy artifacts + register in target registry |

---

## Self-Check Questions

1. Why do we use separate state files per environment instead of Terraform workspaces?
2. What makes the VPC CIDR different across environments and why?
3. How does the CI/CD pipeline prevent accidental changes to production?
4. What is the model promotion workflow from dev to staging to prod?
5. Which resources have `environment == "prod"` conditionals and what do they control?

---

## You Know You Have Completed This Module When...

- [ ] Environment tfvars files are created for dev, staging, and prod
- [ ] Each environment deploys with its own Terraform state
- [ ] VPC CIDRs are non-overlapping across environments
- [ ] CI/CD workflow runs `terraform plan` on PRs and `terraform apply` on merge
- [ ] Model promotion script copies artifacts between environment buckets
- [ ] Production environment has Multi-AZ RDS and deletion protection
- [ ] Validation script passes: `bash modules/10-production-platform/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: Terraform state conflict between environments**
```bash
# Verify you are using the correct state key
terraform show | head -5

# Re-initialize with the correct backend key
terraform init -reconfigure \
  -backend-config="key=ml-platform/dev/terraform.tfstate"
```

**Issue: CI/CD permissions error**
```bash
# Verify the GitHub Actions OIDC role has required permissions
aws sts get-caller-identity  # Should show the CI/CD role ARN
```

**Issue: Resource name collision between environments**
```bash
# All resource names should include the environment
# Check for hardcoded names without ${var.environment}
grep -r '"ml-platform-' terraform/modules/ | grep -v var.environment
```

---

**Next: [Capstone Project -->](../../capstone/)**
