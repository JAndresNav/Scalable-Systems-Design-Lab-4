output "alb_dns_name" {
  description = "Public hostname of the load balancer."
  value       = aws_lb.main.dns_name
}

output "base_url" {
  description = "Base URL for the test scripts and any manual requests."
  value       = "http://${aws_lb.main.dns_name}"
}

output "seed_url" {
  description = "Re-applies sql/schema.sql. Terraform already calls this during apply; row counts live in the SQL file, not in query parameters."
  value       = "http://${aws_lb.main.dns_name}/init"
}

output "cached_url" {
  description = "Cache-aside read. First call is a MISS, the rest are HITs until the TTL expires."
  value       = "http://${aws_lb.main.dns_name}/product?id=42"
}

output "uncached_url" {
  description = "Same read with the cache bypassed; every call pays the full RDS cost."
  value       = "http://${aws_lb.main.dns_name}/product?id=42&nocache=1"
}

output "rds_endpoint" {
  description = "Private MySQL endpoint. Only reachable from the Lambda security group."
  value       = aws_db_instance.main.address
}

output "redis_endpoint" {
  description = "Private Redis primary endpoint."
  value       = aws_elasticache_replication_group.main.primary_endpoint_address
}

output "db_password" {
  description = "Generated master password."
  value       = random_password.db.result
  sensitive   = true
}

output "lambda_function_name" {
  description = "Function name, for tailing logs with `aws logs tail`."
  value       = aws_lambda_function.api.function_name
}
