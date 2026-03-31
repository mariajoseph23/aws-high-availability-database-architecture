# =============================================================================
# Subnet Configuration for High-Availability Database Architecture
# =============================================================================
# Creates public, private application, and private database subnets
# across multiple Availability Zones with proper route tables.
#
# Subnet Layout (per AZ):
#   Public:           10.0.1x.0/24  — NAT Gateways, Bastion hosts
#   Private (App):    10.0.2x.0/24  — Application servers
#   Private (DB):     10.0.3x.0/24  — RDS instances (isolated)
# =============================================================================

# -----------------------------------------------------------------------------
# Public Subnets — used for NAT Gateways and bastion/jump hosts
# -----------------------------------------------------------------------------

resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, 10 + count.index) # 10.0.10.0/24, 10.0.11.0/24, ...
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.environment}-public-${var.availability_zones[count.index]}"
    Tier = "public"
  }
}

# -----------------------------------------------------------------------------
# Private Application Subnets — for app servers that talk to the database
# -----------------------------------------------------------------------------

resource "aws_subnet" "private_app" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 20 + count.index) # 10.0.20.0/24, 10.0.21.0/24, ...
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.environment}-private-app-${var.availability_zones[count.index]}"
    Tier = "private-app"
  }
}

# -----------------------------------------------------------------------------
# Private Database Subnets — isolated tier for RDS instances only
# -----------------------------------------------------------------------------

resource "aws_subnet" "private_db" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, 30 + count.index) # 10.0.30.0/24, 10.0.31.0/24, ...
  availability_zone = var.availability_zones[count.index]

  tags = {
    Name = "${var.environment}-private-db-${var.availability_zones[count.index]}"
    Tier = "private-db"
  }
}

# -----------------------------------------------------------------------------
# RDS Subnet Group — tells RDS which subnets it can deploy into
# -----------------------------------------------------------------------------

resource "aws_db_subnet_group" "main" {
  name        = "${var.environment}-ha-database-subnet-group"
  description = "Subnet group for HA database deployment across multiple AZs"
  subnet_ids  = aws_subnet.private_db[*].id

  tags = {
    Name = "${var.environment}-db-subnet-group"
  }
}

# -----------------------------------------------------------------------------
# Route Tables
# -----------------------------------------------------------------------------

# Public route table — routes internet traffic through the IGW
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.environment}-public-rt"
  }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private route tables — one per AZ; all use the same NAT when single_nat_gateway is true
resource "aws_route_table" "private" {
  count  = length(var.availability_zones)
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
  }

  tags = {
    Name = "${var.environment}-private-rt-${var.availability_zones[count.index]}"
  }
}

resource "aws_route_table_association" "private_app" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_app[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

resource "aws_route_table_association" "private_db" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private_db[count.index].id
  route_table_id = aws_route_table.private[count.index].id
}

# -----------------------------------------------------------------------------
# Outputs
# -----------------------------------------------------------------------------

output "public_subnet_ids" {
  description = "IDs of the public subnets"
  value       = aws_subnet.public[*].id
}

output "private_app_subnet_ids" {
  description = "IDs of the private application subnets"
  value       = aws_subnet.private_app[*].id
}

output "private_db_subnet_ids" {
  description = "IDs of the private database subnets"
  value       = aws_subnet.private_db[*].id
}

output "db_subnet_group_name" {
  description = "Name of the RDS subnet group"
  value       = aws_db_subnet_group.main.name
}
