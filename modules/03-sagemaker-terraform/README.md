# Module 03: SageMaker with Terraform

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Intermediate |
| **Prerequisites** | Modules 01-02 completed, VPC deployed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Deploy SageMaker Studio domain in VPC-only mode with Terraform
- Create user profiles for data scientists and ML engineers
- Provision notebook instances with auto-stop lifecycle configuration
- Set up a SageMaker Model Package Group for model versioning
- Configure KMS encryption for notebooks and training data
- Submit SageMaker training jobs using the Python SDK

---

## Concepts

### SageMaker Components

| Component | Purpose | Terraform Resource |
|---|---|---|
| **Studio Domain** | Managed IDE with JupyterLab, code editor, terminals | `aws_sagemaker_domain` |
| **User Profile** | Per-user settings within a Studio domain | `aws_sagemaker_user_profile` |
| **Notebook Instance** | Standalone managed Jupyter notebook (EC2-backed) | `aws_sagemaker_notebook_instance` |
| **Processing Job** | Run data preprocessing or evaluation scripts | Created via SDK/API |
| **Training Job** | Run model training with managed infrastructure | Created via SDK/API |
| **Model Package Group** | Versioned model registry for approval workflows | `aws_sagemaker_model_package_group` |
| **Endpoint** | Real-time inference serving | Created via SDK/API or Terraform |

### SageMaker Architecture in Our Platform

```
+------------------------------------------------------------+
|  SageMaker Studio Domain (VPC-only mode)                   |
|  +--------------------------+  +------------------------+  |
|  | User: data-scientist     |  | User: ml-engineer      |  |
|  | - JupyterLab             |  | - JupyterLab           |  |
|  | - Code Editor            |  | - Code Editor          |  |
|  | - Terminal               |  | - Pipeline Builder     |  |
|  +--------------------------+  +------------------------+  |
+------------------------------------------------------------+
        |                                    |
        v                                    v
+------------------+              +-------------------+
| Training Jobs    |              | Model Registry    |
| ml.m5.xlarge     |              | (Package Group)   |
| - Input: S3      |              | - Version 1.0     |
| - Output: S3     |              | - Version 1.1     |
| - Metrics: CW    |              | - Approved/Rejected|
+------------------+              +-------------------+
        |                                    |
        v                                    v
+------------------+              +-------------------+
| Model Artifacts  |              | Inference Endpoint|
| s3://models/     |              | ml.m5.large       |
+------------------+              +-------------------+
```

---

## Hands-On Lab

### Exercise 1: Deploy the SageMaker Module

**Step 1:** Review the SageMaker Terraform configuration:

```bash
cat terraform/modules/sagemaker/main.tf
```

Key configuration for the Studio domain:

```hcl
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
  }

  kms_key_id = var.kms_key_arn  # Encrypt EFS storage
}
```

**Step 2:** Deploy the SageMaker module (requires VPC and IAM modules):

```bash
cd terraform/

# Plan the full deployment
terraform plan

# Apply SageMaker and its dependencies
terraform apply -target=module.iam -target=module.s3
terraform apply -target=module.sagemaker
```

**Step 3:** Verify the domain was created:

```bash
# Get Studio domain ID
terraform output sagemaker_studio_domain_id

# Get the Studio URL
terraform output sagemaker_studio_url
```

### Exercise 2: Notebook Instance with Auto-Stop

The module provisions a standalone notebook instance with a lifecycle configuration that automatically stops idle notebooks:

```hcl
resource "aws_sagemaker_notebook_instance" "main" {
  name                    = "${var.project_name}-${var.environment}-notebook"
  role_arn                = var.sagemaker_execution_role_arn
  instance_type           = var.notebook_instance_type
  subnet_id               = var.private_subnet_ids[0]
  security_groups         = [var.sagemaker_security_group_id]
  kms_key_id              = var.kms_key_arn
  direct_internet_access  = "Disabled"   # VPC-only mode
  root_access             = "Disabled"   # Security best practice
  volume_size             = 50

  lifecycle_config_name = aws_sagemaker_notebook_instance_lifecycle_configuration.auto_stop.name
}
```

**Verify the notebook instance:**

```bash
aws sagemaker describe-notebook-instance \
  --notebook-instance-name ml-platform-dev-notebook \
  --query '{Status:NotebookInstanceStatus,InstanceType:InstanceType,DirectInternet:DirectInternetAccess}'
```

### Exercise 3: Submit a Training Job with Python SDK

Create a Python script to submit a SageMaker training job:

```python
# scripts/submit_training_job.py
import boto3
import sagemaker
from sagemaker.estimator import Estimator
from dotenv import load_dotenv
import os

load_dotenv()

# Initialize SageMaker session
session = sagemaker.Session()
role = os.getenv("SAGEMAKER_ROLE_ARN")
bucket = os.getenv("MODEL_ARTIFACTS_BUCKET")

# Define the training estimator
estimator = Estimator(
    image_uri=sagemaker.image_uris.retrieve("xgboost", session.boto_region_name, "1.7-1"),
    role=role,
    instance_count=1,
    instance_type="ml.m5.xlarge",
    output_path=f"s3://{bucket}/training-output",
    sagemaker_session=session,
    encrypt_inter_container_traffic=True,
    subnets=os.getenv("PRIVATE_SUBNET_IDS", "").split(","),
    security_group_ids=[os.getenv("SAGEMAKER_SECURITY_GROUP_ID")],
    hyperparameters={
        "max_depth": 5,
        "eta": 0.2,
        "gamma": 4,
        "min_child_weight": 6,
        "subsample": 0.8,
        "objective": "binary:logistic",
        "num_round": 100,
    },
    tags=[
        {"Key": "Project", "Value": "ml-platform"},
        {"Key": "Environment", "Value": "dev"},
    ],
)

# Start training (uses VPC networking)
training_input = sagemaker.inputs.TrainingInput(
    s3_data=f"s3://{os.getenv('DATA_LAKE_BUCKET')}/processed/train/",
    content_type="csv",
)

estimator.fit({"train": training_input}, wait=True)

print(f"Model artifacts: {estimator.model_data}")
print(f"Training job: {estimator.latest_training_job.name}")
```

### Exercise 4: Register a Model in the Package Group

```python
# scripts/register_model.py
import boto3
import sagemaker
from dotenv import load_dotenv
import os

load_dotenv()

sm_client = boto3.client("sagemaker")

# Register a model version
response = sm_client.create_model_package(
    ModelPackageGroupName=f"{os.getenv('PROJECT_NAME', 'ml-platform')}-dev-models",
    ModelPackageDescription="XGBoost classifier v1.0",
    InferenceSpecification={
        "Containers": [
            {
                "Image": sagemaker.image_uris.retrieve("xgboost", "us-east-1", "1.7-1"),
                "ModelDataUrl": "s3://ml-platform-dev-model-artifacts/training-output/model.tar.gz",
            }
        ],
        "SupportedContentTypes": ["text/csv"],
        "SupportedResponseMIMETypes": ["text/csv"],
    },
    ModelApprovalStatus="PendingManualApproval",
)

print(f"Model package ARN: {response['ModelPackageArn']}")
```

---

## SageMaker Instance Type Guide

| Use Case | Recommended Instance | vCPU | Memory | GPU | Cost/hr (on-demand) |
|---|---|---|---|---|---|
| Notebooks / exploration | ml.t3.medium | 2 | 4 GiB | - | ~$0.05 |
| Data preprocessing | ml.m5.xlarge | 4 | 16 GiB | - | ~$0.23 |
| Model training (CPU) | ml.m5.2xlarge | 8 | 32 GiB | - | ~$0.46 |
| Model training (GPU) | ml.g4dn.xlarge | 4 | 16 GiB | 1x T4 | ~$0.74 |
| Deep learning training | ml.p3.2xlarge | 8 | 61 GiB | 1x V100 | ~$3.83 |
| Inference endpoint | ml.m5.large | 2 | 8 GiB | - | ~$0.12 |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Public internet on notebooks | Security audit failure | Set `direct_internet_access = "Disabled"` |
| Root access enabled | Privilege escalation risk | Set `root_access = "Disabled"` |
| Missing KMS encryption | Compliance violation | Set `kms_key_id` on domain and notebooks |
| No auto-stop lifecycle | Runaway notebook costs | Attach lifecycle configuration |
| Wrong subnet for notebook | Cannot reach S3/ECR | Use private subnet with VPC endpoints |

---

## Self-Check Questions

1. What is the difference between SageMaker Studio and a standalone notebook instance?
2. Why do we set `direct_internet_access = "Disabled"` on the notebook instance?
3. How does the auto-stop lifecycle configuration help with cost management?
4. What role does the Model Package Group play in the ML lifecycle?
5. Why do we encrypt inter-container traffic during training?

---

## You Know You Have Completed This Module When...

- [ ] SageMaker Studio domain is deployed in VPC-only mode
- [ ] Two user profiles are created (data-scientist, ml-engineer)
- [ ] Notebook instance is running with auto-stop lifecycle
- [ ] Model Package Group exists for model versioning
- [ ] KMS encryption is enabled for all SageMaker resources
- [ ] Validation script passes: `bash modules/03-sagemaker-terraform/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: Studio domain fails to create**
```bash
# Check if a domain already exists (only one per region per account)
aws sagemaker list-domains --query 'Domains[*].{ID:DomainId,Name:DomainName,Status:Status}'
```

**Issue: Notebook instance stuck in "Pending"**
```bash
# Check the CloudWatch logs
aws logs get-log-events \
  --log-group-name /aws/sagemaker/NotebookInstances \
  --log-stream-name ml-platform-dev-notebook/jupyter-server
```

**Issue: Training job fails with VPC error**
```bash
# Verify the execution role has VPC permissions
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw sagemaker_execution_role_arn) \
  --action-names ec2:CreateNetworkInterface ec2:DescribeNetworkInterfaces
```

---

**Next: [Module 04 - MLflow Infrastructure -->](../04-mlflow-infrastructure/)**
