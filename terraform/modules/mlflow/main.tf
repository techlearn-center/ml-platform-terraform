# =============================================================================
# MLflow Module - Tracking Server on ECS Fargate with RDS Backend
# =============================================================================
# Deploys MLflow tracking server as a containerized service on ECS Fargate,
# backed by RDS PostgreSQL for metadata and S3 for artifact storage.
# An Application Load Balancer provides the HTTP endpoint.
# =============================================================================

variable "project_name" {
  type = string
}

variable "environment" {
  type = string
}

variable "vpc_id" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "public_subnet_ids" {
  type = list(string)
}

variable "mlflow_security_group_id" {
  type = string
}

variable "rds_security_group_id" {
  type = string
}

variable "mlflow_bucket_name" {
  type = string
}

variable "mlflow_execution_role_arn" {
  type = string
}

variable "mlflow_task_role_arn" {
  type = string
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.small"
}

variable "mlflow_container_cpu" {
  type    = number
  default = 512
}

variable "mlflow_container_memory" {
  type    = number
  default = 1024
}

# -----------------------------------------------------------------------------
# RDS PostgreSQL - MLflow metadata backend store
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "mlflow" {
  name       = "${var.project_name}-${var.environment}-mlflow-db"
  subnet_ids = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-db-subnet"
  }
}

resource "random_password" "mlflow_db" {
  length  = 32
  special = false
}

resource "aws_secretsmanager_secret" "mlflow_db" {
  name                    = "${var.project_name}-${var.environment}-mlflow-db-password"
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-db-secret"
  }
}

resource "aws_secretsmanager_secret_version" "mlflow_db" {
  secret_id = aws_secretsmanager_secret.mlflow_db.id
  secret_string = jsonencode({
    username = "mlflow"
    password = random_password.mlflow_db.result
    host     = aws_db_instance.mlflow.address
    port     = 5432
    dbname   = "mlflow"
  })
}

resource "aws_db_instance" "mlflow" {
  identifier     = "${var.project_name}-${var.environment}-mlflow"
  engine         = "postgres"
  engine_version = "15.4"
  instance_class = var.db_instance_class

  allocated_storage     = 20
  max_allocated_storage = 100
  storage_encrypted     = true

  db_name  = "mlflow"
  username = "mlflow"
  password = random_password.mlflow_db.result

  db_subnet_group_name   = aws_db_subnet_group.mlflow.name
  vpc_security_group_ids = [var.rds_security_group_id]

  backup_retention_period = 7
  skip_final_snapshot     = var.environment != "prod"
  deletion_protection     = var.environment == "prod"

  multi_az = var.environment == "prod"

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-db"
  }
}

# -----------------------------------------------------------------------------
# ECS Cluster
# -----------------------------------------------------------------------------
resource "aws_ecs_cluster" "mlflow" {
  name = "${var.project_name}-${var.environment}-mlflow"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-cluster"
  }
}

# -----------------------------------------------------------------------------
# CloudWatch Log Group
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "mlflow" {
  name              = "/ecs/${var.project_name}-${var.environment}-mlflow"
  retention_in_days = 30

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-logs"
  }
}

# -----------------------------------------------------------------------------
# ECS Task Definition - MLflow container
# -----------------------------------------------------------------------------
resource "aws_ecs_task_definition" "mlflow" {
  family                   = "${var.project_name}-${var.environment}-mlflow"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.mlflow_container_cpu
  memory                   = var.mlflow_container_memory
  execution_role_arn       = var.mlflow_execution_role_arn
  task_role_arn            = var.mlflow_task_role_arn

  container_definitions = jsonencode([
    {
      name  = "mlflow"
      image = "ghcr.io/mlflow/mlflow:v2.10.0"

      command = [
        "mlflow", "server",
        "--host", "0.0.0.0",
        "--port", "5000",
        "--backend-store-uri", "postgresql://mlflow:${random_password.mlflow_db.result}@${aws_db_instance.mlflow.address}:5432/mlflow",
        "--default-artifact-root", "s3://${var.mlflow_bucket_name}/artifacts",
        "--serve-artifacts"
      ]

      portMappings = [
        {
          containerPort = 5000
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.mlflow.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "mlflow"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:5000/health || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 60
      }

      essential = true
    }
  ])

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-task"
  }
}

data "aws_region" "current" {}

# -----------------------------------------------------------------------------
# ECS Service
# -----------------------------------------------------------------------------
resource "aws_ecs_service" "mlflow" {
  name            = "${var.project_name}-${var.environment}-mlflow"
  cluster         = aws_ecs_cluster.mlflow.id
  task_definition = aws_ecs_task_definition.mlflow.arn
  desired_count   = var.environment == "prod" ? 2 : 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [var.mlflow_security_group_id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mlflow.arn
    container_name   = "mlflow"
    container_port   = 5000
  }

  depends_on = [aws_lb_listener.mlflow]

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-service"
  }
}

# -----------------------------------------------------------------------------
# Application Load Balancer
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "${var.project_name}-${var.environment}-mlflow-alb-"
  vpc_id      = var.vpc_id
  description = "Security group for MLflow ALB"

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["10.0.0.0/16"]
    description = "HTTP from VPC"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound"
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-alb-sg"
  }
}

resource "aws_lb" "mlflow" {
  name               = "${var.project_name}-${var.environment}-mlflow"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.private_subnet_ids

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-alb"
  }
}

resource "aws_lb_target_group" "mlflow" {
  name        = "${var.project_name}-${var.environment}-mlflow"
  port        = 5000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200"
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    timeout             = 5
    unhealthy_threshold = 3
  }

  tags = {
    Name = "${var.project_name}-${var.environment}-mlflow-tg"
  }
}

resource "aws_lb_listener" "mlflow" {
  load_balancer_arn = aws_lb.mlflow.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mlflow.arn
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------
output "tracking_uri" {
  value = "http://${aws_lb.mlflow.dns_name}"
}

output "rds_endpoint" {
  value = aws_db_instance.mlflow.address
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.mlflow.name
}

output "ecs_service_name" {
  value = aws_ecs_service.mlflow.name
}
