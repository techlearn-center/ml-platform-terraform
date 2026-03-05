# Module 02: VPC and Networking for ML Workloads

| | |
|---|---|
| **Time** | 3-5 hours |
| **Difficulty** | Beginner-Intermediate |
| **Prerequisites** | Module 01 completed, Terraform backend configured |

---

## Learning Objectives

By the end of this module, you will be able to:

- Design a VPC topology with public and private subnets for ML workloads
- Configure NAT gateways for outbound internet access from private subnets
- Set up VPC endpoints to reduce costs and improve security for S3/ECR/SageMaker
- Create security groups that enforce network-level isolation between components
- Understand why ML workloads require private networking

---

## Concepts

### Why Private Networking for ML?

ML workloads handle sensitive data (PII, financial, healthcare). Running SageMaker notebooks and training jobs in private subnets ensures:

- Data never traverses the public internet
- Network-level access control via security groups
- Compliance with HIPAA, SOC2, and GDPR requirements
- Reduced attack surface for model endpoints

### VPC Architecture for ML

```
+--------------------------------------------------------------------+
|  VPC: 10.0.0.0/16                                                  |
|                                                                     |
|  +-- Public Subnets (ALB, NAT) ---------------------------------+  |
|  |  10.0.0.0/24 (AZ-a)  |  10.0.1.0/24 (AZ-b)  | 10.0.2.0/24  |  |
|  |  [NAT GW] [ALB]      |  [NAT GW*]            | [NAT GW*]    |  |
|  +---------------------------------------------------------------+  |
|                           |                                         |
|  +-- Private Subnets (ML Workloads) ----------------------------+  |
|  |  10.0.10.0/24 (AZ-a) |  10.0.11.0/24 (AZ-b) | 10.0.12.0/24 |  |
|  |  [SageMaker]         |  [ECS/MLflow]         | [RDS]         |  |
|  |  [Notebooks]         |  [Training Jobs]      | [PostgreSQL]  |  |
|  +---------------------------------------------------------------+  |
|                                                                     |
|  +-- VPC Endpoints --+                                              |
|  |  S3 (Gateway)     |  <-- Free, avoids NAT costs for S3          |
|  |  ECR API (IF)     |  <-- Pull container images privately         |
|  |  ECR DKR (IF)     |  <-- Docker layer downloads                  |
|  |  SageMaker API    |  <-- SageMaker API calls stay in VPC         |
|  |  SageMaker Runtime|  <-- Inference calls stay in VPC             |
|  |  CloudWatch Logs  |  <-- Log shipping stays in VPC               |
|  +-------------------+                                              |
|                                                                     |
|  * NAT GW per AZ only in prod; single NAT in dev to save cost      |
+--------------------------------------------------------------------+
```

### Key Terminology

| Term | Definition |
|---|---|
| **VPC** | Virtual Private Cloud -- isolated virtual network in AWS |
| **CIDR Block** | IP address range (e.g., 10.0.0.0/16 = 65,536 IPs) |
| **NAT Gateway** | Allows private subnet resources to reach the internet |
| **VPC Endpoint** | Private connection to AWS services without internet traversal |
| **Security Group** | Stateful firewall rules controlling inbound/outbound traffic |
| **Gateway Endpoint** | Free VPC endpoint type for S3 and DynamoDB |
| **Interface Endpoint** | ENI-based VPC endpoint for other AWS services (has hourly cost) |

---

## Hands-On Lab

### Exercise 1: Deploy the VPC Module

**Step 1:** Review the VPC Terraform module:

```bash
cat terraform/modules/vpc/main.tf
```

Key resources created by this module:
- `aws_vpc.main` -- The VPC with DNS support enabled
- `aws_subnet.public[*]` -- Public subnets across AZs (for ALB, NAT)
- `aws_subnet.private[*]` -- Private subnets across AZs (for ML workloads)
- `aws_nat_gateway.main[*]` -- NAT gateway(s) for outbound internet
- `aws_vpc_endpoint.*` -- VPC endpoints for S3, ECR, SageMaker, Logs

**Step 2:** Deploy just the VPC module to see networking come up first:

```bash
cd terraform/

# Target only the VPC module
terraform plan -target=module.vpc

# Apply the VPC module
terraform apply -target=module.vpc
```

**Step 3:** Verify the VPC was created:

```bash
# Get the VPC ID from Terraform output
terraform output vpc_id

# Verify subnets
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'Subnets[*].{ID:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock,Public:MapPublicIpOnLaunch}' \
  --output table
```

### Exercise 2: Understand the NAT Gateway Strategy

The VPC module uses a cost-aware pattern: one NAT gateway in dev, one per AZ in prod.

```hcl
# From terraform/modules/vpc/main.tf:
resource "aws_nat_gateway" "main" {
  # Single NAT in dev (saves ~$32/month per extra NAT)
  # One per AZ in prod (high availability)
  count = var.environment == "prod" ? length(var.availability_zones) : 1

  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}
```

**Cost implications:**

| Environment | NAT Gateways | Monthly Cost (NAT only) |
|---|---|---|
| dev | 1 | ~$32 + data transfer |
| prod | 3 (one per AZ) | ~$96 + data transfer |

**Why this matters:** NAT data transfer costs add up fast for ML workloads that download large datasets. VPC endpoints for S3 bypass NAT entirely.

### Exercise 3: Configure VPC Endpoints

VPC endpoints are critical for ML platforms. Without them, every S3 API call from SageMaker or MLflow goes through the NAT gateway, incurring data transfer charges.

```hcl
# Gateway endpoint for S3 (free)
resource "aws_vpc_endpoint" "s3" {
  vpc_id       = aws_vpc.main.id
  service_name = "com.amazonaws.${data.aws_region.current.name}.s3"
  route_table_ids = aws_route_table.private[*].id
}

# Interface endpoint for SageMaker API
resource "aws_vpc_endpoint" "sagemaker_api" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sagemaker.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true
}
```

**Verify the S3 endpoint is routing traffic correctly:**

```bash
# From an instance in the private subnet, test S3 access
# The route table should show the VPC endpoint as the target for S3
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'RouteTables[*].Routes[?DestinationPrefixListId!=`null`]'
```

### Exercise 4: Review Security Groups

Each component gets its own security group with minimal access:

```hcl
# SageMaker security group -- only HTTPS and Jupyter from within VPC
resource "aws_security_group" "sagemaker" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]    # Only from within VPC
  }

  ingress {
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]    # Jupyter notebook port
  }
}

# RDS security group -- only PostgreSQL from MLflow containers
resource "aws_security_group" "rds" {
  vpc_id = aws_vpc.main.id

  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.mlflow.id]  # Only from MLflow
  }
}
```

**Key principle:** Security groups reference other security groups (not CIDR blocks) when possible, so access follows the service dependency graph.

---

## Network Cost Optimization Tips

| Technique | Savings | How |
|---|---|---|
| S3 Gateway Endpoint | 100% of S3 NAT transfer | Route S3 traffic through free VPC endpoint |
| Single NAT in dev | ~$64/month | Use `count` conditional on environment |
| Interface endpoints | Reduces NAT traffic | $7.20/month per endpoint per AZ but saves data transfer |
| Same-AZ placement | Avoids cross-AZ fees | Place training jobs and data in same AZ |

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---|---|---|
| Missing S3 VPC endpoint | High NAT data transfer costs | Add gateway endpoint for S3 |
| SageMaker without VPC | Notebooks have public internet | Set `direct_internet_access = "Disabled"` |
| Too broad security groups | Failed security audit | Use security group references, not 0.0.0.0/0 for ingress |
| Overlapping CIDR blocks | Cannot peer VPCs | Plan CIDR ranges with `cidrsubnet()` |

---

## Self-Check Questions

1. Why do ML workloads belong in private subnets rather than public ones?
2. What is the difference between a Gateway VPC endpoint and an Interface VPC endpoint?
3. How does the NAT gateway strategy differ between dev and prod, and why?
4. Why does the RDS security group reference the MLflow security group instead of a CIDR block?
5. What happens to SageMaker API calls when you add a SageMaker VPC endpoint?

---

## You Know You Have Completed This Module When...

- [ ] VPC with public and private subnets is deployed
- [ ] NAT gateway is operational (private subnet instances can reach the internet)
- [ ] S3 VPC endpoint is routing traffic
- [ ] Security groups are created for SageMaker, MLflow, and RDS
- [ ] `terraform output vpc_id` returns a valid VPC ID
- [ ] Validation script passes: `bash modules/02-vpc-and-networking/validation/validate.sh`

---

## Troubleshooting

### Common Issues

**Issue: NAT gateway creation fails**
```bash
# Check your Elastic IP quota
aws ec2 describe-account-attributes \
  --attribute-names vpc-max-elastic-ips
```

**Issue: VPC endpoint not working**
```bash
# Verify endpoint status
aws ec2 describe-vpc-endpoints \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}'
```

**Issue: Private subnet has no internet**
```bash
# Verify NAT gateway is in the route table
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=$(terraform output -raw vpc_id)" \
  --query 'RouteTables[*].{Routes:Routes}'
```

---

**Next: [Module 03 - SageMaker with Terraform -->](../03-sagemaker-terraform/)**
