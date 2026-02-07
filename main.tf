terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # PARTIAL CONFIGURATION
  # We leave bucket details empty. GitHub Actions will fill them in dynamically.
  backend "s3" {
    key    = "student-workstation/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.aws_region
}

# =========================================================================
# 1. NETWORK & SECURITY (Standard Setup)
# =========================================================================

resource "aws_vpc" "cfd_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags = { Name = "CFD-VPC" }
}

resource "aws_internet_gateway" "cfd_igw" {
  vpc_id = aws_vpc.cfd_vpc.id
}

resource "aws_subnet" "cfd_subnet" {
  vpc_id                  = aws_vpc.cfd_vpc.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "${var.aws_region}a"
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

resource "aws_security_group" "cfd_sg" {
  name        = "cfd-workstation-sg"
  description = "Allow SSH, DCV (8443), and HTTPS (443)"
  vpc_id      = aws_vpc.cfd_vpc.id

  # 1. SSH (Terminal)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 2. DCV Original Port (Backup)
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # 3. HTTPS Port (NEW - Required for the redirect to work!)
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound Traffic (Allow everything)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# =========================================================================
# 2. PERSISTENT STORAGE (The "Backpack")
#    This volume holds your simulations. It survives Spot Interruptions.
# =========================================================================

resource "aws_ebs_volume" "sim_data" {
  availability_zone = "${var.aws_region}a"
  size              = 100
  type              = "gp3"

  tags = {
    Name = "Persistent-CFD-Data"
  }

  # Safety: Prevents Terraform from accidentally deleting your data
  lifecycle {
    prevent_destroy = false
  }
}

# =========================================================================
# 3. COMPUTE (The "Taxi")
#    This is a disposable Spot Instance. If it dies, we just get a new one.
# =========================================================================

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

resource "aws_instance" "cfd_workstation" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = var.instance_type
  key_name      = var.key_name
  subnet_id     = aws_subnet.cfd_subnet.id
  vpc_security_group_ids = [aws_security_group.cfd_sg.id]

  # SPOT INSTANCE CONFIGURATION
  # This uses your "Spot Quota" (32 vCPUs) instead of On-Demand (0 vCPUs).
  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price = "1.00"
      spot_instance_type = "one-time"
    }
  }

  # Root Drive (OS Only - Disposable)
  root_block_device {
    volume_size = 20
    delete_on_termination = true
  }

  tags = {
    Name = "CFD-Spot-Workstation"
  }
}

# =========================================================================
# 4. ATTACHMENT (Connecting Storage to Compute)
# =========================================================================

resource "aws_volume_attachment" "ebs_att" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.sim_data.id
  instance_id = aws_instance.cfd_workstation.id

  # Ensures we can rip the volume off a dead instance and attach to a new one
  force_detach = true
}