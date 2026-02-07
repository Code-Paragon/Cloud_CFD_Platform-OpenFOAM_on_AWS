terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # PARTIAL CONFIGURATION
  # We leave this empty. GitHub Actions will fill it in.
  backend "s3" {
    key    = "student-workstation/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# =========================================================================
# 1. NETWORKING LAYER
#    Simple, isolated network to give the workstation internet access.
# =========================================================================

resource "aws_vpc" "cfd_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name    = "CFD-Workstation-VPC"
    Project = "Aerospace-Sims"
  }
}

resource "aws_internet_gateway" "cfd_igw" {
  vpc_id = aws_vpc.cfd_vpc.id
}

resource "aws_subnet" "cfd_subnet" {
  vpc_id                  = aws_vpc.cfd_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true # Critical: Ensures user gets a Public IP on Resume
  availability_zone       = "${var.aws_region}a"

  tags = {
    Name = "CFD-Public-Subnet"
  }
}

resource "aws_route_table" "cfd_rt" {
  vpc_id = aws_vpc.cfd_vpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.cfd_igw.id
  }
}

resource "aws_route_table_association" "cfd_rta" {
  subnet_id      = aws_subnet.cfd_subnet.id
  route_table_id = aws_route_table.cfd_rt.id
}

# =========================================================================
# 2. SECURITY LAYER (The Firewall)
#    Ports 22 (SSH) and 8443 (NICE DCV).
# =========================================================================

resource "aws_security_group" "cfd_sg" {
  name        = "cfd-workstation-sg"
  description = "Allow SSH and DCV Remote Desktop"
  vpc_id      = aws_vpc.cfd_vpc.id

  # SSH Access (For Ansible configuration)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # In production, restrict to User IP
  }

  # NICE DCV Access (For 3D Desktop Stream)
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Access (For downloading OpenFOAM/updates)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================================================================
# 3. COMPUTE LAYER (The Workstation)
#    On-Demand g4dn.xlarge with a 100GB Persistent Root Volume.
# =========================================================================

# Fetch the latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "cfd_workstation" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = "g4dn.xlarge"      # NVIDIA T4 GPU, 4 vCPUs, 16GB RAM
  key_name               = var.key_name       # SSH Key Pair
  subnet_id              = aws_subnet.cfd_subnet.id
  vpc_security_group_ids = [aws_security_group.cfd_sg.id]

  # STORAGE: 150GB Single Drive
  # Logic: Enough space for OS (10GB) + Sim Data (140GB).
  root_block_device {
    volume_size           = 100
    volume_type           = "gp3"  # Cost-effective, high performance
    delete_on_termination = true   # IF you 'Destroy', data is wiped.
  }

  tags = {
    Name    = "Student-CFD-Workstation"
    Project = "Aerospace-Sims"
  }
}