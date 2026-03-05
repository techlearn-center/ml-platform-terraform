# Module 09: Cost Management (Reserved Instances, Spot Training, Auto-Shutdown)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Advanced |
| **Prerequisites** | Modules 01-08 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Estimate and track ML platform infrastructure costs
- Configure SageMaker managed spot training for up to 90% savings
- Implement auto-shutdown for idle notebooks and endpoints
- Use reserved instances for always-on components (RDS, NAT)
- Set up AWS Budgets and Cost Explorer tags for cost allocation
- Design cost-aware Terraform configurations that differ by environment

---

## Concepts

### ML Platform Cost Breakdown

ML infrastructure costs can spiral quickly. Understanding where money goes is critical.

```
+-------------------------------------------------------------------+
|              Typical ML Platform Monthly Costs (dev)               |
+-------------------------------------------------------------------+
|                                                                     |
|  +-------------------+------------------------------------------+  |
|  | Component         | Est. Monthly Cost | Optimization          |  |
|  +-------------------+------------------------------------------+  |
|  | NAT Gateway       | $32 + data xfer   | Single NAT in dev     |  |
|  | SageMaker Notebook| $36 (ml.t3.med)   | Auto-stop after 1hr   |  |
|  | SageMaker Training| Variable          | Spot instances (90%)  |  |
|  | ECS Fargate (MLflow)| $15-30          | Right-size CPU/memory |  |
|  | RDS PostgreSQL    | $25 (db.t3.small) | Reserved in prod      |  |
|  | S3 Storage        | $0.023/GB         | Lifecycle policies    |  |
|  | VPC Endpoints     | $7.20 each/AZ     | Only deploy needed    |  |
|  | KMS               | $1/key + API      | Bucket keys reduce    |  |
|  | CloudWatch        | $0.30/metric      | Custom metrics only   |  |
|  +-------------------+------------------------------------------+  |
|                                                                     |
|  Dev Total: ~$150-300/month (without training)                     |
|  Prod Total: ~$500-2000/month (with HA and more endpoints)        |
+-------------------------------------------------------------------+
```

### Cost Optimization Strategies

| Strategy | Savings | Where | How |
|---|---|---|---|
| Spot training | Up to 90% | SageMaker training | `use_spot_instances = true` |
| Auto-stop notebooks | 100% idle time | SageMaker notebooks | Lifecycle configuration |
| Single NAT in dev | ~$64/month | VPC module | Conditional `count` |
| S3 lifecycle | 40-80% storage | S3 module | Transition to IA/Glacier |
| VPC S3 endpoint | 100% NAT data | VPC module | Gateway endpoint (free) |
| Right-size Fargate | 20-50% | ECS/MLflow | Match CPU/memory to load |
| Reserved RDS | 30-60% | RDS instances | 1-year or 3-year commitment |
| Endpoint auto-scaling | Variable | SageMaker endpoints | Scale to zero off-hours |

---

## Hands-On Lab

### Exercise 1: Configure Spot Training

SageMaker managed spot training uses EC2 spot instances at up to 90% discount:

```python
# scripts/spot_training.py
import sagemaker
from sagemaker.estimator import Estimator
from dotenv import load_dotenv
import os

load_dotenv()

session = sagemaker.Session()
role = os.getenv("SAGEMAKER_ROLE_ARN")

estimator = Estimator(
    image_uri=sagemaker.image_uris.retrieve("xgboost", session.boto_region_name, "1.7-1"),
    role=role,
    instance_count=1,
    instance_type="ml.m5.xlarge",
    output_path=f"s3://{os.getenv('MODEL_ARTIFACTS_BUCKET')}/training-output",

    # Spot training configuration
    use_spot_instances=True,              # Enable spot
    max_run=3600,                          # Max training time: 1 hour
    max_wait=7200,                         # Max wait for spot: 2 hours
    checkpoint_s3_uri=f"s3://{os.getenv('MODEL_ARTIFACTS_BUCKET')}/checkpoints/",

    hyperparameters={
        "max_depth": 5,
        "eta": 0.2,
        "num_round": 100,
        "objective": "binary:logistic",
    },
)

# The checkpoint_s3_uri is critical: if the spot instance is interrupted,
# training resumes from the last checkpoint instead of starting over
training_input = sagemaker.inputs.TrainingInput(
    s3_data=f"s3://{os.getenv('DATA_LAKE_BUCKET')}/processed/train/",
    content_type="csv",
)

estimator.fit({"train": training_input}, wait=True)

# Check the savings
training_job = session.describe_training_job(estimator.latest_training_job.name)
billable = training_job.get("BillableTimeInSeconds", 0)
total = training_job.get("TrainingTimeInSeconds", 0)
if total > 0:
    savings = (1 - billable / total) * 100
    print(f"Spot savings: {savings:.1f}% (billed {billable}s of {total}s)")
```

### Exercise 2: Environment-Aware Cost Configuration

The platform uses Terraform conditionals to reduce dev costs:

```hcl
# VPC Module: Single NAT in dev, multi-AZ in prod
resource "aws_nat_gateway" "main" {
  count = var.environment == "prod" ? length(var.availability_zones) : 1
  # Dev: 1 NAT = ~$32/month
  # Prod: 3 NAT = ~$96/month (but HA)
}

# MLflow: Single replica in dev, multi in prod
resource "aws_ecs_service" "mlflow" {
  desired_count = var.environment == "prod" ? 2 : 1
  # Dev: 1 task = ~$15/month
  # Prod: 2 tasks = ~$30/month (but HA)
}

# RDS: Single-AZ in dev, Multi-AZ in prod
resource "aws_db_instance" "mlflow" {
  multi_az            = var.environment == "prod"
  deletion_protection = var.environment == "prod"
  skip_final_snapshot = var.environment != "prod"
  # Dev: ~$25/month (single-AZ)
  # Prod: ~$50/month (multi-AZ)
}
```

### Exercise 3: Auto-Shutdown for SageMaker Resources

The notebook lifecycle configuration (from Module 03) stops idle notebooks:

```hcl
resource "aws_sagemaker_notebook_instance_lifecycle_configuration" "auto_stop" {
  name = "${var.project_name}-${var.environment}-auto-stop"

  on_start = base64encode(<<-EOF
    #!/bin/bash
    set -e
    IDLE_TIME=3600  # Stop after 1 hour idle
    echo "Auto-stop configured with ${IDLE_TIME}s timeout"
  EOF
  )
}
```

For endpoints, implement auto-scaling that scales to zero during off-hours:

```hcl
resource "aws_appautoscaling_target" "sagemaker_endpoint" {
  max_capacity       = 4
  min_capacity       = 0      # Scale to zero off-hours
  resource_id        = "endpoint/${var.project_name}-${var.environment}-endpoint/variant/AllTraffic"
  scalable_dimension = "sagemaker:variant:DesiredInstanceCount"
  service_namespace  = "sagemaker"
}

resource "aws_appautoscaling_scheduled_action" "scale_down" {
  name               = "${var.project_name}-${var.environment}-scale-down"
  service_namespace  = aws_appautoscaling_target.sagemaker_endpoint.service_namespace
  resource_id        = aws_appautoscaling_target.sagemaker_endpoint.resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_endpoint.scalable_dimension
  schedule           = "cron(0 22 * * ? *)"  # 10 PM UTC daily

  scalable_target_action {
    min_capacity = 0
    max_capacity = 0
  }
}

resource "aws_appautoscaling_scheduled_action" "scale_up" {
  name               = "${var.project_name}-${var.environment}-scale-up"
  service_namespace  = aws_appautoscaling_target.sagemaker_endpoint.service_namespace
  resource_id        = aws_appautoscaling_target.sagemaker_endpoint.resource_id
  scalable_dimension = aws_appautoscaling_target.sagemaker_endpoint.scalable_dimension
  schedule           = "cron(0 8 * * ? *)"   # 8 AM UTC daily

  scalable_target_action {
    min_capacity = 1
    max_capacity = 4
  }
}
```

### Exercise 4: Cost Tracking with Tags

Ensure all resources have consistent tags for cost allocation:

```hcl
# In terraform/main.tf -- provider default_tags
provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
```

Query costs by tag using the Cost Explorer API:

```python
# scripts/cost_report.py
import boto3
from datetime import datetime, timedelta
from dotenv import load_dotenv
import os

load_dotenv()

ce = boto3.client("ce")

# Get costs for the current month grouped by service
today = datetime.today()
start = today.replace(day=1).strftime("%Y-%m-%d")
end = today.strftime("%Y-%m-%d")

response = ce.get_cost_and_usage(
    TimePeriod={"Start": start, "End": end},
    Granularity="MONTHLY",
    Filter={
        "Tags": {
            "Key": "Project",
            "Values": [os.getenv("PROJECT_NAME", "ml-platform")],
        }
    },
    Metrics=["BlendedCost"],
    GroupBy=[
        {"Type": "DIMENSION", "Key": "SERVICE"}
    ],
)

print(f"ML Platform Costs ({start} to {end}):")
print("-" * 50)

total = 0
for group in response["ResultsByTime"][0]["Groups"]:
    service = group["Keys"][0]
    cost = float(group["Metrics"]["BlendedCost"]["Amount"])
    if cost > 0.01:
        print(f"  {service:40s} ${cost:>8.2f}")
        total += cost

print("-" * 50)
print(f"  {'Total':40s} ${total:>8.2f}")
```

---

## Cost Comparison: Dev vs Prod

| Resource | Dev Monthly | Prod Monthly | Savings Technique |
|---|---|---|---|
| NAT Gateway | $32 (1x) | $96 (3x) | Single NAT in dev |
| SageMaker Notebook | $36 | $36 | Auto-stop lifecycle |
| Training Jobs | ~$50 (spot) | ~$500 (spot) | Managed spot (90% off) |
| MLflow ECS | $15 (1 task) | $30 (2 tasks) | Right-size Fargate |
| RDS PostgreSQL | $25 (single-AZ) | $50 (multi-AZ) | Reserved in prod |
| S3 Storage | $5 | $50 | Lifecycle policies |
| VPC Endpoints | $22 (3 IF) | $65 (3 IF x 3 AZ) | Only deploy needed |
| **Total** | **~$185** | **~$827** | |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| No spot training | 90% higher training costs | Set `use_spot_instances = true` |
| Notebook running 24/7 | $36/month wasted | Attach auto-stop lifecycle config |
| Multi-AZ RDS in dev | Double the dev cost | `multi_az = var.environment == "prod"` |
| No S3 lifecycle rules | Growing storage costs | Add transition to IA after 30 days |
| Missing resource tags | Cannot track costs per project | Use `default_tags` in AWS provider |
| No budget alerts | Surprise AWS bill | Set AWS Budgets at 80% threshold |

---

## Self-Check Questions

1. How do SageMaker managed spot instances work, and why are checkpoints critical?
2. What is the difference in NAT gateway costs between dev and prod configurations?
3. How does scaling SageMaker endpoints to zero during off-hours save money?
4. Why do we use S3 bucket keys with KMS encryption to reduce costs?
5. How would you estimate monthly costs before deploying to production?

---

## You Know You Have Completed This Module When...

- [ ] Spot training is configured and produces a training job
- [ ] Auto-stop lifecycle is attached to notebook instances
- [ ] Environment conditionals reduce dev costs vs prod
- [ ] AWS Budget is set with email alerts
- [ ] Cost report script shows costs grouped by service
- [ ] Resource tags are consistent across all components
- [ ] Validation script passes: `bash modules/09-cost-management/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: Spot training keeps getting interrupted**
```bash
# Check spot instance availability in your region
aws ec2 describe-spot-instance-requests \
  --query 'SpotInstanceRequests[?Status.Code==`capacity-not-available`]'

# Try a different instance type or increase max_wait
```

**Issue: Budget alerts not sending emails**
```bash
# Check budget configuration
aws budgets describe-budget \
  --account-id $(aws sts get-caller-identity --query Account --output text) \
  --budget-name ml-platform-dev-monthly-budget
```

---

**Next: [Module 10 - Multi-Environment Deployment -->](../10-production-platform/)**
