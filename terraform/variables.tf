variable "aws_region" {
  description = "Region for every resource in this stack."
  type        = string
  default     = "us-east-1"
}

variable "aws_profile" {
  description = "Local AWS CLI profile holding the Academy lab credentials."
  type        = string
  default     = "academy"
}

variable "name_prefix" {
  description = "Prefix applied to every resource name."
  type        = string
  default     = "lab4"
}

variable "az_count" {
  description = "How many availability zones to spread the ALB and subnet groups across. Minimum 2, required by the ALB."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2
    error_message = "An ALB needs subnets in at least two availability zones."
  }
}

variable "allowed_cidr" {
  description = "CIDR allowed to reach the ALB on port 80. Narrow this to your own IP/32 if you prefer."
  type        = string
  default     = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# RDS
# ---------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class. db.t3.micro is what the Academy lab allows."
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "MySQL version. 8.0 is needed for the recursive CTE used to seed data."
  type        = string
  default     = "8.0.46"
}

variable "db_allocated_storage" {
  description = "Storage in GiB for the RDS instance."
  type        = number
  default     = 20
}

variable "db_name" {
  description = "Initial database name."
  type        = string
  default     = "lab4"
}

variable "db_username" {
  description = "Master username. 'admin' is reserved by RDS, so do not use it."
  type        = string
  default     = "lab4admin"
}

variable "db_multi_az" {
  description = "Run RDS as Multi-AZ. Doubles cost and apply time; off by default for the lab."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# ElastiCache
# ---------------------------------------------------------------------------

variable "cache_node_type" {
  description = "ElastiCache node type."
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "cache_node_count" {
  description = "Nodes in the replication group. 1 = single node. 2+ enables a read replica and automatic failover."
  type        = number
  default     = 1
}

# ---------------------------------------------------------------------------
# Lambda
# ---------------------------------------------------------------------------

variable "lambda_memory_mb" {
  description = "Lambda memory. CPU scales with memory, so this also sets how fast JSON and the MySQL protocol are parsed."
  type        = number
  default     = 1024
}

variable "lambda_timeout" {
  description = "Lambda timeout in seconds. /init seeding needs the headroom."
  type        = number
  default     = 120
}

variable "lambda_reserved_concurrency" {
  description = <<-EOT
    Ceiling on concurrent executions. Also reserves that capacity so other
    functions cannot starve this one. The Academy account allows 400 total;
    -1 disables the setting entirely.
  EOT
  type        = number
  default     = 200
}

variable "lambda_provisioned_concurrency" {
  description = <<-EOT
    Pre-warmed execution environments, which removes cold starts from the p99.
    Costs roughly USD 0.015 per hour per unit at 1024 MB, so it is off (0) by
    default. Set to 10-20 before a load test to see flat tail latency.
  EOT
  type        = number
  default     = 0
}

variable "cache_ttl_seconds" {
  description = "Default TTL for cached products."
  type        = number
  default     = 300
}
