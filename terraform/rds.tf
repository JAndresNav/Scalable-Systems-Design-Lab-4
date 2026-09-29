resource "random_password" "db" {
  length  = 24
  special = false # RDS rejects /, @, ", and space; dropping specials avoids surprises
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.name_prefix}-db"
  subnet_ids = local.subnet_ids

  tags = { Name = "${var.name_prefix}-db" }
}

# max_connections on db.t3.micro defaults to roughly 60. Lambda can scale to
# 200 concurrent executions, so without the cache in front this database is the
# first thing to fall over -- which is exactly what ?nocache=1 demonstrates.
resource "aws_db_parameter_group" "main" {
  name_prefix = "${var.name_prefix}-mysql80-"
  family      = "mysql8.0"
  description = "Lab 4 MySQL tuning"

  parameter {
    name  = "max_connections"
    value = "150"
  }

  # Log anything slower than 200 ms so the uncached path shows up in the RDS
  # slow query log during the load test.
  parameter {
    name  = "slow_query_log"
    value = "1"
  }

  parameter {
    name  = "long_query_time"
    value = "0.2"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "main" {
  identifier = "${var.name_prefix}-mysql"

  engine         = "mysql"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_allocated_storage * 2
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.main.name
  publicly_accessible    = false
  multi_az               = var.db_multi_az

  # Lab settings: no backups and no final snapshot keeps destroy fast and free.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  # The Academy lab role cannot create the enhanced-monitoring service role.
  monitoring_interval          = 0
  performance_insights_enabled = false

  tags = { Name = "${var.name_prefix}-mysql" }
}
