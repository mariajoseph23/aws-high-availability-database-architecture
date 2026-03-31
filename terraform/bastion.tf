# =============================================================================
# Bastion — public subnet, SSM Session Manager + optional SSH key
# =============================================================================

variable "bastion_key_name" {
  description = "Optional EC2 key pair name for SSH; SSM works without a key"
  type        = string
  default     = ""
}

# t4g.* = Graviton (arm64); t3.* / t2.* = x86_64
data "aws_ami" "bastion" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = [startswith(var.bastion_instance_type, "t4g") ? "al2023-ami-*-arm64" : "al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_iam_role" "bastion_ssm" {
  name = "${var.environment}-bastion-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = {
    Name = "${var.environment}-bastion-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "bastion_ssm_core" {
  role       = aws_iam_role.bastion_ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.environment}-bastion-ssm-profile"
  role = aws_iam_role.bastion_ssm.name
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.bastion.id
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  key_name               = var.bastion_key_name != "" ? var.bastion_key_name : null

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  user_data = <<-EOT
    #!/bin/bash
    set -e
    dnf install -y postgresql15
  EOT

  tags = {
    Name = "${var.environment}-bastion"
    Role = "bastion"
  }

  depends_on = [aws_iam_role_policy_attachment.bastion_ssm_core]
}

variable "bastion_instance_type" {
  description = "EC2 instance type (e.g. t4g.micro, t3.micro) — use t4g.* for lowest cost with Graviton"
  type        = string
  default     = "t4g.micro"
}

output "bastion_instance_id" {
  description = "Instance ID (use: aws ssm start-session --target <id>)"
  value       = aws_instance.bastion.id
}

output "bastion_private_ip" {
  description = "Private IP of the bastion"
  value       = aws_instance.bastion.private_ip
}

output "bastion_public_ip" {
  description = "Public IP (if applicable)"
  value       = aws_instance.bastion.public_ip
}

output "bastion_ssm_hint" {
  description = "Connect without SSH key"
  value       = "aws ssm start-session --target ${aws_instance.bastion.id} --region ${var.aws_region}"
}
