# The Academy lab cannot create IAM roles or NAT gateways, so this stack reuses
# the default VPC. Lambda, RDS and ElastiCache all sit inside it and talk to
# each other over private addresses; only the ALB is reachable from outside.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

locals {
  # Sort by AZ so the chosen subnets are stable across plans, then take the
  # first az_count of them. us-east-1e does not offer every instance family,
  # so deterministic ordering (a, b, c, ...) matters here.
  subnets_by_az = { for s in data.aws_subnet.default : s.availability_zone => s.id }
  selected_azs  = slice(sort(keys(local.subnets_by_az)), 0, var.az_count)
  subnet_ids    = [for az in local.selected_azs : local.subnets_by_az[az]]
}

# ---------------------------------------------------------------------------
# Security groups: one per tier, each referencing the one in front of it.
# ---------------------------------------------------------------------------

resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb"
  description = "Public entry point for the load balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP from clients"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  egress {
    description = "ALB to targets"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda"
  description = "VPC-attached Lambda; needs egress to RDS and ElastiCache only"
  vpc_id      = data.aws_vpc.default.id

  # No ingress rule: the ALB reaches the function through the Lambda API, not
  # over the network, so nothing ever connects to these ENIs.

  egress {
    description = "Outbound to data tier"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name_prefix}-lambda" }
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds"
  description = "MySQL, reachable only from the Lambda security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "MySQL from Lambda"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = { Name = "${var.name_prefix}-rds" }
}

resource "aws_security_group" "redis" {
  name        = "${var.name_prefix}-redis"
  description = "Redis, reachable only from the Lambda security group"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Redis from Lambda"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = { Name = "${var.name_prefix}-redis" }
}
