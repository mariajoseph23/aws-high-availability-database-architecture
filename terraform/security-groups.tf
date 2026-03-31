# =============================================================================
# Security Groups for High-Availability Database Architecture
# =============================================================================
# Implements a layered security model:
#   Bastion SG  →  can SSH into bastion hosts from allowed CIDRs
#   App SG      →  app servers can reach the database on port 5432
#   Database SG →  only accepts traffic from the App SG on port 5432
# =============================================================================

# -----------------------------------------------------------------------------
# Variables
# -----------------------------------------------------------------------------

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to SSH into the bastion host"
  type        = list(string)
  default     = ["0.0.0.0/0"] # Restrict this in production!
}

variable "db_port" {
  description = "Port number for the database engine"
  type        = number
  default     = 5432
}

# -----------------------------------------------------------------------------
# Bastion Host Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "bastion" {
  name        = "${var.environment}-bastion-sg"
  description = "Security group for bastion/jump hosts in public subnets"
  vpc_id      = aws_vpc.main.id

  # Inbound: SSH from allowed CIDRs
  ingress {
    description = "SSH access from allowed CIDRs"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  # Outbound: allow all (needed for package updates, database access, etc.)
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-bastion-sg"
  }
}

# -----------------------------------------------------------------------------
# Application Tier Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "application" {
  name        = "${var.environment}-application-sg"
  description = "Security group for application servers in private app subnets"
  vpc_id      = aws_vpc.main.id

  # Inbound: SSH from bastion hosts
  ingress {
    description     = "SSH from bastion hosts"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Inbound: HTTPS traffic (if serving web traffic through ALB)
  ingress {
    description = "HTTPS from within VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Inbound: HTTP traffic
  ingress {
    description = "HTTP from within VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  # Outbound: allow all
  egress {
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.environment}-application-sg"
  }
}

# -----------------------------------------------------------------------------
# Database Tier Security Group
# -----------------------------------------------------------------------------

resource "aws_security_group" "database" {
  name        = "${var.environment}-database-sg"
  description = "Security group for RDS instances - app tier and bastion only on 5432"
  vpc_id      = aws_vpc.main.id

  # Inbound: PostgreSQL from application tier only
  ingress {
    description     = "PostgreSQL access from application servers"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.application.id]
  }

  # Inbound: PostgreSQL from bastion (for admin/debugging)
  ingress {
    description     = "PostgreSQL access from bastion for admin tasks"
    from_port       = var.db_port
    to_port         = var.db_port
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  # Outbound: restrict to VPC only (database shouldn't reach the internet)
  egress {
    description = "Allow outbound within VPC only"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  tags = {
    Name = "${var.environment}-database-sg"
  }
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "bastion_sg_id" {
  description = "Security group ID for bastion hosts"
  value       = aws_security_group.bastion.id
}

output "application_sg_id" {
  description = "Security group ID for application servers"
  value       = aws_security_group.application.id
}

output "database_sg_id" {
  description = "Security group ID for RDS instances"
  value       = aws_security_group.database.id
}
