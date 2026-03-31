aws_region         = "us-east-1"
environment        = "production"
vpc_cidr           = "10.0.0.0/16"
availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

# Single NAT = faster deploy + lower cost (set false for one NAT per AZ)
single_nat_gateway = true

# Small sizes for testing
db_instance_class                = "db.t4g.micro"
bastion_instance_type            = "t4g.micro"
db_allocated_storage             = 20
db_max_allocated_storage         = 100
db_backup_retention_period       = 1
rds_performance_insights_enabled = false
enable_db_deletion_protection    = false
rds_skip_final_snapshot          = true

db_name     = "appdb"
db_username = "dbadmin"

bastion_key_name = ""

allowed_cidr_blocks = ["YourIP/32"]
