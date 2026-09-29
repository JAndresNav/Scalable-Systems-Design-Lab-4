resource "aws_lb" "main" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  internal           = false

  # Spread across az_count zones. The ALB scales its own capacity per zone, so
  # more zones means more headroom before it starts queueing connections.
  subnets         = local.subnet_ids
  security_groups = [aws_security_group.alb.id]

  idle_timeout               = 60
  drop_invalid_header_fields = true
  enable_deletion_protection = false

  # Cross-zone balancing is always on for ALBs; noted here because it is what
  # keeps one hot zone from skewing the load test results.

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "lambda" {
  name        = "${var.name_prefix}-tg"
  target_type = "lambda"

  # No health_check block on purpose. A Lambda target group has health checks
  # off by default, and writing the block out makes the provider send its own
  # defaults (interval 30, protocol HTTP) — which AWS rejects for target_type
  # "lambda" with "Health check interval must be greater than the timeout".

  lambda_multi_value_headers_enabled = false

  tags = { Name = "${var.name_prefix}-tg" }
}

# The ALB invokes the function through the Lambda API, so it needs an explicit
# resource policy entry rather than a network path.
resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowInvokeFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda.arn
}

# Target the alias, not $LATEST, so provisioned concurrency actually serves the
# traffic when it is switched on.
resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = aws_lambda_alias.live.arn

  depends_on = [aws_lambda_permission.alb]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda.arn
  }
}
