# The Academy lab cannot create IAM roles, so the function reuses the
# pre-provisioned LabRole, which already carries AWSLambdaVPCAccessExecutionRole.
data "aws_iam_role" "lab" {
  name = "LabRole"
}

# Built by scripts/build_lambda.sh, which downloads the pure-Python wheels for
# pymysql and redis and drops them next to handler.py.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/../build/lambda"
  output_path = "${path.module}/../build/lambda.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name_prefix}-api"
  retention_in_days = 3
}

resource "aws_lambda_function" "api" {
  function_name = "${var.name_prefix}-api"
  role          = data.aws_iam_role.lab.arn

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  runtime = "python3.12"
  handler = "handler.handler"

  # Provisioned concurrency can only attach to a published version, never to
  # $LATEST, so every apply publishes one and the alias moves onto it.
  publish = true

  # CPU is allocated in proportion to memory. At 1024 MB the function gets a
  # full vCPU, which roughly halves JSON and MySQL protocol parsing time
  # compared with the 128 MB default.
  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout

  # Attaching to the VPC is what lets the function reach RDS and ElastiCache on
  # their private addresses. Hyperplane ENIs are shared, so this no longer adds
  # the multi-second cold start it used to.
  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  environment {
    variables = {
      DB_HOST       = aws_db_instance.main.address
      DB_PORT       = tostring(aws_db_instance.main.port)
      DB_USER       = var.db_username
      DB_PASSWORD   = random_password.db.result
      DB_NAME       = var.db_name
      REDIS_HOST    = aws_elasticache_replication_group.main.primary_endpoint_address
      REDIS_PORT    = "6379"
      CACHE_TTL     = tostring(var.cache_ttl_seconds)
      CACHE_VERSION = "v1"
    }
  }

  depends_on = [aws_cloudwatch_log_group.lambda]

  tags = { Name = "${var.name_prefix}-api" }
}

# A published version is required before provisioned concurrency can point at
# anything; aliases also give the load test a stable target to shift.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version
}

# Pre-warmed environments. Off by default (count 0) because it bills by the
# hour; turn it on for the load test to take cold starts out of the tail.
resource "aws_lambda_provisioned_concurrency_config" "live" {
  count = var.lambda_provisioned_concurrency > 0 ? 1 : 0

  function_name                     = aws_lambda_function.api.function_name
  qualifier                         = aws_lambda_alias.live.name
  provisioned_concurrent_executions = var.lambda_provisioned_concurrency
}
