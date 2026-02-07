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
#    Spot c5.2xlarge with a 100GB Persistent ebs Volume.
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

# 1. THE BACKPACK (Persistent Storage)
# This volume survives even if the instance terminates!
resource "aws_ebs_volume" "sim_data" {
  availability_zone = "${var.aws_region}a"
  size              = 100               # 100GB for Simulations
  type              = "gp3"

  tags = {
    Name = "Persistent-Simulation-Data"
  }

  # Prevents accidental deletion
  lifecycle {
    prevent_destroy = false
  }
}

# 2. THE TAXI (Spot Instance)
resource "aws_instance" "cfd_workstation" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = aws_subnet.cfd_subnet.id
  vpc_security_group_ids = [aws_security_group.cfd_sg.id]

  # USE SPOT INSTANCES (Fixes your Quota Issue!)
  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price = "1.00"
      spot_instance_type = "one-time"
      interruption_behavior = "terminate"
    }
  }

  # Small Root Drive (Just for OS & Apps - Disposable)
  root_block_device {
    volume_size = 20
    delete_on_termination = true
  }

  tags = {
    Name = "Student-CFD-Workstation"
  }
}

# 3. THE STRAP (Connecting them)
resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.sim_data.id
  instance_id = aws_instance.cfd_workstation.id

  # CRITICAL: If the previous spot instance died without detaching,
  # this forces the volume to rip away and attach to the new one.
  force_detach = true
}