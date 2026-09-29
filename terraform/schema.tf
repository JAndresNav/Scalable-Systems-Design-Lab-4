# Apply sql/schema.sql as soon as the database is reachable.
#
# RDS is not publicly accessible, so there is no path from this machine to run
# a .sql file against it. The Lambda is already inside the VPC and already
# carries the file in its package, so Terraform invokes it once with
# {"path": "/init"} and the function executes the statements.
#
# Re-running terraform apply does not re-seed unless schema.sql itself changed:
# its hash is part of the invocation input, and aws_lambda_invocation only
# re-invokes when the input changes.
resource "aws_lambda_invocation" "schema" {
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name

  input = jsonencode({
    path                  = "/init"
    httpMethod            = "GET"
    queryStringParameters = {}
    # Not read by the handler. It is here so that editing schema.sql changes
    # the input and therefore triggers a fresh run.
    schema_sha256 = filesha256("${path.module}/../sql/schema.sql")
  })

  depends_on = [
    aws_db_instance.main,
    aws_elasticache_replication_group.main,
  ]
}

output "schema_result" {
  description = "Row counts and statement list returned by the seeding run."
  value       = jsondecode(aws_lambda_invocation.schema.result).body
}
