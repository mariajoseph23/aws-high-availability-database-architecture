# =============================================================================
# RDS — Multi-AZ PostgreSQL, optional read replica, KMS, Enhanced Monitoring
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "db_instance_class" {
  description = "RDS instance class (db.t4g.micro is sufficient for testing; scale up for production load)"
  type        = string
  default     = "db.t4g.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL major version (resolved to latest available in-region)"
  type        = string
  default     = "15"
}

variable "enable_db_deletion_protection" {
  description = "RDS deletion protection"
  type        = bool
  default     = true
}

variable "rds_skip_final_snapshot" {
  description = "If true, terraform destroy skips final snapshot (faster teardown; use for test environments)"
  type        = bool
  default     = false
}

variable "db_name" {
  description = "Name of the default database"
  type        = string
  default     = "appdb"
}

variable "db_username" {
  description = "Master username for the database"
  type        = string
  default     = "dbadmin"
  sensitive   = true
}

variable "db_password" {
  description = "Master password; if null, Terraform generates one (stored in state)"
  type        = string
  default     = null
  sensitive   = true
}

resource "random_password" "db_master" {
  count = var.db_password == null ? 1 : 0

  length  = 32
  special = true
}

variable "db_allocated_storage" {
  description = "Allocated storage in GB (gp3 minimum 20)"
  type        = number
  default     = 20
}

variable "db_max_allocated_storage" {
  description = "Maximum storage for autoscaling in GB"
  type        = number
  default     = 100
}

variable "db_backup_retention_period" {
  description = "Days to retain automated backups"
  type        = number
  default     = 7
}

variable "db_backup_window" {
  description = "Preferred backup window (UTC)"
  type        = string
  default     = "03:00-04:00"
}

variable "db_maintenance_window" {
  description = "Preferred maintenance window (UTC)"
  type        = string
  default     = "sun:04:30-sun:05:30"
}

variable "rds_performance_insights_enabled" {
  description = "Performance Insights (uses KMS key when enabled)"
  type        = bool
  default     = true
}

# -----------------------------------------------------------------------------
# Engine version
# -----------------------------------------------------------------------------

data "aws_rds_engine_version" "postgresql" {
  engine       = "postgres"
  version      = var.db_engine_version
  default_only = true
  include_all  = false
}

# -----------------------------------------------------------------------------
# KMS — encryption at rest
# -----------------------------------------------------------------------------

resource "aws_kms_key" "rds" {
  description             = "KMS key for RDS encryption at rest"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.environment}-rds-kms-key"
  }
}

resource "aws_kms_alias" "rds" {
  name          = "alias/${var.environment}-rds-encryption"
  target_key_id = aws_kms_key.rds.key_id
}

# -----------------------------------------------------------------------------
# DB Parameter Group
# -----------------------------------------------------------------------------

resource "aws_db_parameter_group" "postgresql" {
  name        = "${var.environment}-postgresql15-params"
  family      = "postgres15"
  description = "Custom parameter group for HA PostgreSQL deployment"

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  parameter {
    name  = "log_lock_waits"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name         = "shared_preload_libraries"
    value        = "pg_stat_statements"
    apply_method = "pending-reboot"
  }

  parameter {
    name         = "max_connections"
    value        = "100"
    apply_method = "pending-reboot"
  }

  tags = {
    Name = "${var.environment}-postgresql-params"
  }
}

# -----------------------------------------------------------------------------
# IAM — Enhanced Monitoring
# -----------------------------------------------------------------------------

resource "aws_iam_role" "rds_monitoring" {
  name = "${var.environment}-rds-enhanced-monitoring"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "monitoring.rds.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "${var.environment}-rds-monitoring-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  role       = aws_iam_role.rds_monitoring.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

# -----------------------------------------------------------------------------
# Primary — Multi-AZ
# -----------------------------------------------------------------------------

resource "aws_db_instance" "primary" {
  identifier = "${var.environment}-ha-postgresql-primary"

  engine               = "postgres"
  engine_version       = data.aws_rds_engine_version.postgresql.version
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.postgresql.name

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.rds.arn

  db_name  = var.db_name
  username = var.db_username
  password = var.db_password != null ? var.db_password : random_password.db_master[0].result
  port     = var.db_port

  multi_az = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  backup_retention_period   = var.db_backup_retention_period
  backup_window             = var.db_backup_window
  maintenance_window        = var.db_maintenance_window
  copy_tags_to_snapshot     = true
  skip_final_snapshot       = var.rds_skip_final_snapshot
  final_snapshot_identifier = var.rds_skip_final_snapshot ? null : "${var.environment}-ha-postgresql-final-snapshot"

  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = var.rds_performance_insights_enabled
  performance_insights_kms_key_id       = var.rds_performance_insights_enabled ? aws_kms_key.rds.arn : null
  performance_insights_retention_period = var.rds_performance_insights_enabled ? 7 : null

  auto_minor_version_upgrade  = true
  allow_major_version_upgrade = false

  deletion_protection = var.enable_db_deletion_protection

  tags = {
    Name = "${var.environment}-ha-postgresql-primary"
    Role = "primary"
  }
}

# -----------------------------------------------------------------------------
# Read replica
# -----------------------------------------------------------------------------

resource "aws_db_instance" "read_replica" {
  identifier = "${var.environment}-ha-postgresql-replica"

  replicate_source_db = aws_db_instance.primary.identifier

  instance_class = var.db_instance_class

  storage_type      = "gp3"
  storage_encrypted = true
  kms_key_id        = aws_kms_key.rds.arn

  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false

  monitoring_interval                   = 60
  monitoring_role_arn                   = aws_iam_role.rds_monitoring.arn
  performance_insights_enabled          = var.rds_performance_insights_enabled
  performance_insights_kms_key_id       = var.rds_performance_insights_enabled ? aws_kms_key.rds.arn : null
  performance_insights_retention_period = var.rds_performance_insights_enabled ? 7 : null

  backup_retention_period = 0

  auto_minor_version_upgrade = true
  skip_final_snapshot        = true

  tags = {
    Name = "${var.environment}-ha-postgresql-replica"
    Role = "read-replica"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "primary_endpoint" {
  description = "Primary RDS endpoint"
  value       = aws_db_instance.primary.endpoint
}

output "primary_arn" {
  description = "Primary RDS ARN"
  value       = aws_db_instance.primary.arn
}

output "replica_endpoint" {
  description = "Read replica endpoint"
  value       = aws_db_instance.read_replica.endpoint
}

output "db_name" {
  description = "Default database name"
  value       = aws_db_instance.primary.db_name
}

output "db_port" {
  description = "Database port"
  value       = aws_db_instance.primary.port
}

output "db_master_password" {
  description = "Auto-generated master password (null if you set var.db_password)"
  value       = length(random_password.db_master) > 0 ? random_password.db_master[0].result : null
  sensitive   = true
}
