terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.4"
    }
  }
}

provider "aws" {
  region = "eu-west-1"
}

# ---------- Inputs you can tweak ----------
variable "vpc_id" {
  description = "Existing default VPC ID"
  type        = string
  default     = "vpc-c61fdcbf"
}

variable "availability_zone" {
  description = "AZ to place the instance in"
  type        = string
  default     = "eu-west-1a"
}

variable "ssh_ingress_cidr" {
  description = "CIDR allowed to SSH (replace with your laptop's IP/32 for tighter security)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "key_name" {
  description = "EC2 key pair name"
  type        = string
  default     = "rhel-t4g-nano-key"
}

variable "private_key_path" {
  description = "Where to save the generated private key"
  type        = string
  default     = "./rhel-t4g-nano-key.pem"
}

# ---------- Find latest official RHEL 9 AMI ----------
# Owner 309956199498 is Red Hat's account for RHEL AMIs.
data "aws_ami" "rhel_arm64" {
  most_recent = true
  owners      = ["309956199498"] # Red Hat

  filter {
    name   = "name"
    values = ["RHEL-9*x86_64*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }
}

# ---------- Get VPC CIDR for subnet creation ----------
data "aws_vpc" "target_vpc" {
  id = var.vpc_id
}

# ---------- Create a subnet in the specified AZ ----------
resource "aws_subnet" "terraform_subnet" {
  vpc_id            = var.vpc_id
  cidr_block        = "172.31.64.0/20"
  availability_zone = var.availability_zone

  tags = { Name = "terraform-subnet" }
}

# ---------- Reference the existing IGW attached to this VPC ----------
data "aws_internet_gateway" "igw" {
  filter {
    name   = "attachment.vpc-id"
    values = [var.vpc_id]
  }
}

# ---------- Security group for SSH ----------
resource "aws_security_group" "ssh" {
  name        = "rhel-t4g-nano-ssh"
  description = "Allow SSH"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ssh_ingress_cidr]
  }

  egress {
    description      = "All outbound"
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = { Name = "rhel-t4g-nano-ssh" }
}

# ---------- Generate an ED25519 SSH key and upload the public key to EC2 ----------
resource "tls_private_key" "ssh" {
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  key_name   = var.key_name
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "private_key" {
  filename        = var.private_key_path
  content         = tls_private_key.ssh.private_key_openssh
  file_permission = "0600"
}

# ---------- EC2 instance: RHEL on t3.small with a public IP ----------
resource "aws_instance" "rhel" {
  ami                         = data.aws_ami.rhel_arm64.id
  instance_type               = "t3.small"
  availability_zone           = var.availability_zone
  subnet_id                   = aws_subnet.terraform_subnet.id
  vpc_security_group_ids      = [aws_security_group.ssh.id]
  key_name                    = aws_key_pair.this.key_name
  associate_public_ip_address = true

  tags = { Name = "rhel-t4g-nano" }
}

# ---------- Helpful outputs ----------
output "instance_public_ip" {
  description = "Public IPv4 of the instance"
  value       = aws_instance.rhel.public_ip
}

output "ami_used" {
  description = "RHEL AMI used"
  value = {
    id   = data.aws_ami.rhel_arm64.id
    name = data.aws_ami.rhel_arm64.name
  }
}

output "ssh_command" {
  description = "Copy/paste to connect"
  value       = "ssh -i ${var.private_key_path} ec2-user@${aws_instance.rhel.public_ip}"
  sensitive   = false
}