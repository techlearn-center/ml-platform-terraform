# Module 07: Monitoring and Observability for ML

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Advanced |
| **Prerequisites** | Modules 01-06 completed |

---

## Learning Objectives

By the end of this module, you will be able to:

- Set up CloudWatch dashboards for ML platform infrastructure
- Create CloudWatch alarms for SageMaker endpoint latency and errors
- Configure cost anomaly alerts with AWS Budgets
- Monitor MLflow tracking server health via ECS metrics
- Implement SageMaker Model Monitor for data drift detection
- Build custom CloudWatch metrics for ML-specific KPIs

---

## Concepts

### ML Observability Stack

ML platforms require monitoring at three levels:

```
+-------------------------------------------------------------------+
|                   ML Observability Pyramid                         |
+-------------------------------------------------------------------+
|                                                                     |
|                    +-------------------+                            |
|                    |  ML Metrics       |  Model accuracy, drift,   |
|                    |  (Model Monitor)  |  prediction distribution  |
|                    +-------------------+                            |
|                                                                     |
|              +-----------------------------+                        |
|              |  Application Metrics        |  Endpoint latency,    |
|              |  (CloudWatch Metrics)       |  error rates, P99     |
|              +-----------------------------+                        |
|                                                                     |
|        +-------------------------------------+                      |
|        |  Infrastructure Metrics             |  CPU, memory, disk, |
|        |  (CloudWatch + ECS + RDS)           |  network, cost      |
|        +-------------------------------------+                      |
+-------------------------------------------------------------------+
```

### Key Metrics to Monitor

| Component | Metric | Alarm Threshold | Why |
|---|---|---|---|
| SageMaker Endpoint | `Invocations` | < 1 for 5 min | Endpoint may be down |
| SageMaker Endpoint | `ModelLatency` | > 500ms P99 | SLA violation |
| SageMaker Endpoint | `Invocation4XXErrors` | > 10/min | Client errors |
| SageMaker Endpoint | `Invocation5XXErrors` | > 1/min | Server errors |
| ECS (MLflow) | `CPUUtilization` | > 80% for 5 min | Need to scale up |
| ECS (MLflow) | `MemoryUtilization` | > 85% for 5 min | OOM risk |
| RDS (MLflow DB) | `FreeStorageSpace` | < 5 GB | Disk full risk |
| RDS (MLflow DB) | `CPUUtilization` | > 80% for 10 min | Query performance |
| S3 | `BucketSizeBytes` | > 1 TB | Cost alert |
| AWS Budget | Monthly spend | > $500 | Cost overrun |

---

## Hands-On Lab

### Exercise 1: Create CloudWatch Dashboard

```hcl
# terraform/modules/monitoring/main.tf

resource "aws_cloudwatch_dashboard" "ml_platform" {
  dashboard_name = "${var.project_name}-${var.environment}-ml-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "SageMaker Endpoint Invocations"
          metrics = [
            ["AWS/SageMaker", "Invocations", "EndpointName", "${var.project_name}-${var.environment}-endpoint",
              { stat = "Sum", period = 300 }]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title   = "Endpoint Latency (P50, P99)"
          metrics = [
            ["AWS/SageMaker", "ModelLatency", "EndpointName", "${var.project_name}-${var.environment}-endpoint",
              { stat = "p50", period = 300 }],
            ["AWS/SageMaker", "ModelLatency", "EndpointName", "${var.project_name}-${var.environment}-endpoint",
              { stat = "p99", period = 300 }]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "MLflow ECS CPU & Memory"
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ClusterName", "${var.project_name}-${var.environment}-mlflow",
              "ServiceName", "${var.project_name}-${var.environment}-mlflow",
              { stat = "Average", period = 300 }],
            ["AWS/ECS", "MemoryUtilization", "ClusterName", "${var.project_name}-${var.environment}-mlflow",
              "ServiceName", "${var.project_name}-${var.environment}-mlflow",
              { stat = "Average", period = 300 }]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title   = "RDS CPU & Storage"
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", "${var.project_name}-${var.environment}-mlflow",
              { stat = "Average", period = 300 }],
            ["AWS/RDS", "FreeStorageSpace", "DBInstanceIdentifier", "${var.project_name}-${var.environment}-mlflow",
              { stat = "Average", period = 300 }]
          ]
          view   = "timeSeries"
          region = var.aws_region
        }
      }
    ]
  })
}
```

### Exercise 2: Configure CloudWatch Alarms

```hcl
# SNS topic for alerts
resource "aws_sns_topic" "ml_alerts" {
  name = "${var.project_name}-${var.environment}-ml-alerts"
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.ml_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alarm: SageMaker endpoint high latency
resource "aws_cloudwatch_metric_alarm" "endpoint_latency" {
  alarm_name          = "${var.project_name}-${var.environment}-endpoint-high-latency"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "ModelLatency"
  namespace           = "AWS/SageMaker"
  period              = 300
  statistic           = "p99"
  threshold           = 500000  # 500ms in microseconds
  alarm_description   = "SageMaker endpoint P99 latency exceeds 500ms"
  alarm_actions       = [aws_sns_topic.ml_alerts.arn]

  dimensions = {
    EndpointName = "${var.project_name}-${var.environment}-endpoint"
  }
}

# Alarm: SageMaker endpoint 5XX errors
resource "aws_cloudwatch_metric_alarm" "endpoint_errors" {
  alarm_name          = "${var.project_name}-${var.environment}-endpoint-5xx"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "Invocation5XXErrors"
  namespace           = "AWS/SageMaker"
  period              = 300
  statistic           = "Sum"
  threshold           = 1
  alarm_description   = "SageMaker endpoint returning 5XX errors"
  alarm_actions       = [aws_sns_topic.ml_alerts.arn]

  dimensions = {
    EndpointName = "${var.project_name}-${var.environment}-endpoint"
  }
}

# Alarm: MLflow ECS high CPU
resource "aws_cloudwatch_metric_alarm" "mlflow_cpu" {
  alarm_name          = "${var.project_name}-${var.environment}-mlflow-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  alarm_description   = "MLflow ECS CPU utilization above 80%"
  alarm_actions       = [aws_sns_topic.ml_alerts.arn]

  dimensions = {
    ClusterName = "${var.project_name}-${var.environment}-mlflow"
    ServiceName = "${var.project_name}-${var.environment}-mlflow"
  }
}

# Alarm: RDS free storage low
resource "aws_cloudwatch_metric_alarm" "rds_storage" {
  alarm_name          = "${var.project_name}-${var.environment}-rds-low-storage"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  metric_name         = "FreeStorageSpace"
  namespace           = "AWS/RDS"
  period              = 300
  statistic           = "Average"
  threshold           = 5368709120  # 5 GB in bytes
  alarm_description   = "MLflow RDS free storage below 5 GB"
  alarm_actions       = [aws_sns_topic.ml_alerts.arn]

  dimensions = {
    DBInstanceIdentifier = "${var.project_name}-${var.environment}-mlflow"
  }
}
```

### Exercise 3: AWS Budget Alert

```hcl
resource "aws_budgets_budget" "ml_platform" {
  name         = "${var.project_name}-${var.environment}-monthly-budget"
  budget_type  = "COST"
  limit_amount = var.budget_limit_monthly
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$${var.project_name}"]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}
```

### Exercise 4: Custom ML Metrics with Python

```python
# scripts/publish_ml_metrics.py
import boto3
from datetime import datetime
from dotenv import load_dotenv
import os

load_dotenv()

cloudwatch = boto3.client("cloudwatch")

def publish_model_metrics(endpoint_name, accuracy, drift_score, prediction_count):
    """Publish custom ML metrics to CloudWatch."""
    cloudwatch.put_metric_data(
        Namespace=f"{os.getenv('PROJECT_NAME', 'ml-platform')}/MLMetrics",
        MetricData=[
            {
                "MetricName": "ModelAccuracy",
                "Value": accuracy,
                "Unit": "None",
                "Dimensions": [
                    {"Name": "EndpointName", "Value": endpoint_name},
                    {"Name": "Environment", "Value": os.getenv("ENVIRONMENT", "dev")},
                ],
                "Timestamp": datetime.utcnow(),
            },
            {
                "MetricName": "DataDriftScore",
                "Value": drift_score,
                "Unit": "None",
                "Dimensions": [
                    {"Name": "EndpointName", "Value": endpoint_name},
                    {"Name": "Environment", "Value": os.getenv("ENVIRONMENT", "dev")},
                ],
                "Timestamp": datetime.utcnow(),
            },
            {
                "MetricName": "PredictionCount",
                "Value": prediction_count,
                "Unit": "Count",
                "Dimensions": [
                    {"Name": "EndpointName", "Value": endpoint_name},
                    {"Name": "Environment", "Value": os.getenv("ENVIRONMENT", "dev")},
                ],
                "Timestamp": datetime.utcnow(),
            },
        ],
    )
    print(f"Published metrics for {endpoint_name}: accuracy={accuracy}, drift={drift_score}")


# Example usage
publish_model_metrics(
    endpoint_name="ml-platform-dev-endpoint",
    accuracy=0.945,
    drift_score=0.12,
    prediction_count=15420,
)
```

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| No alarms on endpoints | Downtime goes unnoticed | Set alarms for 5XX errors and latency |
| Dashboard but no alerts | Pretty but useless at 3 AM | Always pair dashboards with SNS alarms |
| Alert fatigue from noisy alarms | Team ignores real alerts | Tune thresholds and evaluation periods |
| Not monitoring costs | Surprise AWS bill | Set budget alerts at 80% and 100% |
| Missing ECS container insights | Cannot debug MLflow issues | Enable `containerInsights` on ECS cluster |

---

## Self-Check Questions

1. What are the three levels of the ML observability pyramid?
2. Why do we use P99 latency instead of average for SageMaker endpoint alarms?
3. How does CloudWatch integrate with SNS for alert notifications?
4. What is data drift and why does it need monitoring in production ML?
5. Why do we set budget alerts at both 80% actual and 100% forecasted?

---

## You Know You Have Completed This Module When...

- [ ] CloudWatch dashboard is created with SageMaker, ECS, and RDS widgets
- [ ] Alarms are configured for endpoint latency, errors, CPU, and storage
- [ ] SNS topic delivers alert emails
- [ ] AWS Budget is set with cost threshold notifications
- [ ] Custom ML metrics are being published to CloudWatch
- [ ] Validation script passes: `bash modules/07-monitoring-infrastructure/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: SNS email subscription stuck in "PendingConfirmation"**
```bash
# Check subscription status
aws sns list-subscriptions-by-topic --topic-arn $(terraform output -raw alert_topic_arn)
# User must click the confirmation link in their email
```

**Issue: CloudWatch alarm stays in INSUFFICIENT_DATA**
```bash
# Verify the metric exists and has data points
aws cloudwatch get-metric-statistics \
  --namespace AWS/SageMaker \
  --metric-name ModelLatency \
  --dimensions Name=EndpointName,Value=ml-platform-dev-endpoint \
  --start-time $(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%S) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%S) \
  --period 300 \
  --statistics p99
```

---

**Next: [Module 08 - Security Hardening -->](../08-security-and-iam/)**
