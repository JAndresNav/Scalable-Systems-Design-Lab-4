resource "aws_elasticache_subnet_group" "main" {
  name       = "${var.name_prefix}-redis"
  subnet_ids = local.subnet_ids
}

# Unlike the RDS equivalent this resource has no name_prefix argument, so the
# name is fixed and changes here replace the group in place.
resource "aws_elasticache_parameter_group" "main" {
  name        = "${var.name_prefix}-redis7"
  family      = "redis7"
  description = "Lab 4 Redis tuning"

  # Evict the least recently used key with a TTL once memory fills, instead of
  # returning OOM errors to the Lambda. A cache that refuses writes under load
  # would silently turn every request back into a database read.
  parameter {
    name  = "maxmemory-policy"
    value = "volatile-lru"
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.name_prefix}-redis"
  description          = "Lab 4 cache-aside store"

  engine         = "redis"
  engine_version = var.cache_engine_version
  node_type      = var.cache_node_type
  port           = 6379

  num_cache_clusters = var.cache_node_count

  # Failover needs at least two nodes; with one, both must be off.
  automatic_failover_enabled = var.cache_node_count > 1
  multi_az_enabled           = var.cache_node_count > 1

  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.redis.id]
  parameter_group_name = aws_elasticache_parameter_group.main.name

  # TLS and AUTH are left off so the demo stays readable; the cache is already
  # unreachable from outside the Lambda security group.
  transit_encryption_enabled = false
  at_rest_encryption_enabled = false

  snapshot_retention_limit = 0
  apply_immediately        = true

  tags = { Name = "${var.name_prefix}-redis" }
}
