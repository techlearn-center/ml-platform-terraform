# Module 04: MLflow on AWS (ECS Fargate + RDS + S3)

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Intermediate |
| **Prerequisites** | Modules 01-03 completed, VPC and IAM deployed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Deploy MLflow tracking server on ECS Fargate with Terraform
- Configure RDS PostgreSQL as the MLflow backend metadata store
- Set up S3 as the MLflow artifact store
- Expose the MLflow UI via an internal Application Load Balancer
- Log experiments from SageMaker training jobs to MLflow
- Query experiment metrics programmatically with the MLflow Python client

---

## Concepts

### Why MLflow for Experiment Tracking?

Without experiment tracking, data scientists lose track of which hyperparameters produced which results. MLflow provides:

- **Experiment Tracking** -- Log parameters, metrics, and artifacts for every run
- **Model Registry** -- Version and stage models (Staging, Production, Archived)
- **Artifact Store** -- Centralized storage for model binaries, plots, data samples
- **Reproducibility** -- Every run records code version, environment, and inputs

### MLflow Architecture on AWS

```
+----------------------------------------------------------------+
|                    MLflow on AWS Architecture                    |
+----------------------------------------------------------------+
|                                                                  |
|  +-----------+     +------------------+     +----------------+  |
|  |  Data     |     |  ALB (internal)  |     |  S3 Artifact   |  |
|  |  Scientist|---->|  Port 80         |     |  Store         |  |
|  |  Notebook |     |  /mlflow         |     |  s3://mlflow/  |  |
|  +-----------+     +--------+---------+     +-------+--------+  |
|                             |                       ^            |
|                             v                       |            |
|                    +--------+---------+             |            |
|                    |  ECS Fargate     |             |            |
|                    |  MLflow Server   +-------------+            |
|                    |  Port 5000       |  artifacts               |
|                    +--------+---------+                          |
|                             |                                    |
|                             v  metadata                          |
|                    +--------+---------+                          |
|                    |  RDS PostgreSQL  |                          |
|                    |  Port 5432       |                          |
|                    |  mlflow database |                          |
|                    +------------------+                          |
+----------------------------------------------------------------+
```

### Key Terminology

| Term | Definition |
|---|---|
| **Tracking Server** | Central server that records experiment data (params, metrics, artifacts) |
| **Backend Store** | Database (PostgreSQL) for storing experiment metadata |
| **Artifact Store** | Object storage (S3) for storing model files, plots, datasets |
| **Run** | A single execution of a training script with logged data |
| **Experiment** | A collection of related runs (e.g., "fraud-detection-v2") |
| **ECS Fargate** | Serverless container hosting -- no EC2 instances to manage |

---

## Hands-On Lab

### Exercise 1: Deploy the MLflow Module

**Step 1:** Review the MLflow Terraform configuration:

```bash
cat terraform/modules/mlflow/main.tf
```

Key resources:
- `aws_db_instance.mlflow` -- RDS PostgreSQL for metadata
- `aws_ecs_cluster.mlflow` -- ECS cluster for the container
- `aws_ecs_task_definition.mlflow` -- Fargate task with MLflow image
- `aws_ecs_service.mlflow` -- Service maintaining desired container count
- `aws_lb.mlflow` -- Internal ALB for HTTP access

**Step 2:** Deploy the MLflow stack:

```bash
cd terraform/

# Apply the MLflow module (depends on VPC, IAM, S3)
terraform apply -target=module.mlflow
```

**Step 3:** Get the MLflow tracking URI:

```bash
# The ALB DNS name is the MLflow endpoint
terraform output mlflow_tracking_uri
# Example: http://ml-platform-dev-mlflow-1234567890.us-east-1.elb.amazonaws.com
```

### Exercise 2: Understand the RDS Configuration

The MLflow backend store uses RDS PostgreSQL with these production features:

```hcl
resource "aws_db_instance" "mlflow" {
  identifier     = "${var.project_name}-${var.environment}-mlflow"
  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.db_instance_class     # db.t3.small for dev

  allocated_storage     = 20
  max_allocated_storage = 100               # Auto-scaling storage
  storage_encrypted     = true              # Encryption at rest

  db_name  = "mlflow"
  username = "mlflow"
  password = random_password.mlflow_db.result  # Generated, stored in Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids = [var.rds_security_group_id]

  backup_retention_period = 7               # 7-day backups
  multi_az               = var.environment == "prod"  # HA in prod only

  skip_final_snapshot = var.environment != "prod"
  deletion_protection = var.environment == "prod"
}
```

**Verify the database:**

```bash
aws rds describe-db-instances \
  --db-instance-identifier ml-platform-dev-mlflow \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Engine:Engine,MultiAZ:MultiAZ,Encrypted:StorageEncrypted}'
```

### Exercise 3: Log Experiments from Python

```python
# scripts/log_experiment.py
import mlflow
import mlflow.sklearn
from sklearn.ensemble import RandomForestClassifier
from sklearn.datasets import make_classification
from sklearn.model_selection import train_test_split
from sklearn.metrics import accuracy_score, f1_score
from dotenv import load_dotenv
import os

load_dotenv()

# Point to the MLflow tracking server (ALB endpoint)
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI"))

# Create or get experiment
experiment_name = "fraud-detection"
mlflow.set_experiment(experiment_name)

# Generate sample data
X, y = make_classification(n_samples=10000, n_features=20, random_state=42)
X_train, X_test, y_train, y_test = train_test_split(X, y, test_size=0.2)

# Run experiment with auto-logging
with mlflow.start_run(run_name="rf-baseline") as run:
    # Log parameters
    params = {"n_estimators": 100, "max_depth": 10, "min_samples_split": 5}
    mlflow.log_params(params)

    # Train model
    model = RandomForestClassifier(**params, random_state=42)
    model.fit(X_train, y_train)

    # Log metrics
    y_pred = model.predict(X_test)
    mlflow.log_metric("accuracy", accuracy_score(y_test, y_pred))
    mlflow.log_metric("f1_score", f1_score(y_test, y_pred))

    # Log the model artifact (saved to S3)
    mlflow.sklearn.log_model(model, "model")

    print(f"Run ID: {run.info.run_id}")
    print(f"Artifact URI: {run.info.artifact_uri}")
```

### Exercise 4: Query Experiments Programmatically

```python
# scripts/query_experiments.py
import mlflow
from dotenv import load_dotenv
import os

load_dotenv()
mlflow.set_tracking_uri(os.getenv("MLFLOW_TRACKING_URI"))

# Search for the best run by accuracy
client = mlflow.MlflowClient()
experiment = client.get_experiment_by_name("fraud-detection")

runs = client.search_runs(
    experiment_ids=[experiment.experiment_id],
    filter_string="metrics.accuracy > 0.9",
    order_by=["metrics.f1_score DESC"],
    max_results=5,
)

print("Top 5 runs by F1 score:")
for run in runs:
    print(f"  Run {run.info.run_id[:8]}... | "
          f"accuracy={run.data.metrics.get('accuracy', 'N/A'):.4f} | "
          f"f1={run.data.metrics.get('f1_score', 'N/A'):.4f} | "
          f"n_estimators={run.data.params.get('n_estimators', 'N/A')}")
```

---

## ECS Fargate Task Definition

The MLflow container runs with these settings:

```hcl
resource "aws_ecs_task_definition" "mlflow" {
  family                   = "${var.project_name}-${var.environment}-mlflow"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = 512    # 0.5 vCPU
  memory                   = 1024   # 1 GB RAM

  container_definitions = jsonencode([{
    name    = "mlflow"
    image   = "ghcr.io/mlflow/mlflow:v2.10.0"
    command = [
      "mlflow", "server",
      "--host", "0.0.0.0",
      "--port", "5000",
      "--backend-store-uri", "postgresql://...",
      "--default-artifact-root", "s3://mlflow-artifacts/",
      "--serve-artifacts"
    ]
    portMappings = [{ containerPort = 5000 }]
    healthCheck = {
      command  = ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"]
      interval = 30
    }
  }])
}
```

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| MLflow pointed at local storage | Artifacts lost when container restarts | Use `--default-artifact-root s3://...` |
| No health check on ECS task | Service never reports healthy | Add health check to container definition |
| RDS publicly accessible | Security vulnerability | Keep RDS in private subnet with SG restrictions |
| Missing Secrets Manager for DB password | Password in plain text in state | Use `random_password` + `aws_secretsmanager_secret` |
| Fargate task too small | OOM kills during heavy logging | Increase memory to 2048+ for production |

---

## Self-Check Questions

1. Why do we use RDS PostgreSQL instead of SQLite for the MLflow backend store?
2. What is the difference between the backend store and the artifact store?
3. Why is the ALB set to `internal = true` instead of internet-facing?
4. How does ECS Fargate differ from running MLflow on an EC2 instance?
5. What happens to experiment data if the ECS container restarts?

---

## You Know You Have Completed This Module When...

- [ ] MLflow tracking server is accessible via the ALB endpoint
- [ ] RDS PostgreSQL is running with encrypted storage
- [ ] S3 artifact bucket is created and accessible
- [ ] Python script successfully logs an experiment to MLflow
- [ ] MLflow UI shows the logged experiment with metrics and artifacts
- [ ] Validation script passes: `bash modules/04-mlflow-infrastructure/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: MLflow container keeps restarting**
```bash
# Check ECS container logs
aws logs tail /ecs/ml-platform-dev-mlflow --follow

# Common cause: RDS not ready yet -- check connectivity
aws rds describe-db-instances --db-instance-identifier ml-platform-dev-mlflow \
  --query 'DBInstances[0].DBInstanceStatus'
```

**Issue: Cannot connect to MLflow from notebook**
```bash
# Verify the ALB is in the same VPC as the notebook
aws elbv2 describe-load-balancers \
  --names ml-platform-dev-mlflow \
  --query 'LoadBalancers[0].{VpcId:VpcId,DNSName:DNSName,Scheme:Scheme}'
```

**Issue: Artifacts not saving to S3**
```bash
# Check the MLflow task role has S3 access
aws iam simulate-principal-policy \
  --policy-source-arn $(terraform output -raw mlflow_execution_role_arn) \
  --action-names s3:PutObject s3:GetObject \
  --resource-arns "arn:aws:s3:::ml-platform-dev-mlflow-artifacts/*"
```

---

**Next: [Module 05 - Data Lake Setup -->](../05-airflow-infrastructure/)**
