terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }

  backend "s3" {
    key    = "student-workstation/terraform.tfstate"
    region = "us-east-1"
  }
}

variable "aws_region" {
  default = "us-east-1"
}

variable "instance_type" {
  default = "c5.2xlarge"
}

# -------------------------------------------------------------------------
# DYNAMIC SSH KEY INGESTION
# -------------------------------------------------------------------------
variable "public_key_material" {
  description = "The public SSH key generated dynamically by GitHub Actions"
  type        = string
}

resource "random_id" "key_suffix" {
  byte_length = 4
}

resource "aws_key_pair" "generated_key" {
  key_name   = "cfd-ephemeral-key-${random_id.key_suffix.hex}"
  public_key = var.public_key_material
}

provider "aws" {
  region = var.aws_region
}

# -------------------------------------------------------------------------
# NETWORK & SECURITY
# -------------------------------------------------------------------------
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

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# -------------------------------------------------------------------------
# STORAGE (The Persistent Backpack)
# -------------------------------------------------------------------------
resource "aws_ebs_volume" "sim_data" {
  availability_zone = "${var.aws_region}a"
  size              = 100
  type              = "gp3"
  tags = { Name = "Persistent-CFD-Data" }
  lifecycle { prevent_destroy = false }
}

# -------------------------------------------------------------------------
# COMPUTE (The Spot Instance)
# -------------------------------------------------------------------------
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

  # Attach the dynamically generated key here
  key_name      = aws_key_pair.generated_key.key_name

  subnet_id     = aws_subnet.cfd_subnet.id
  vpc_security_group_ids = [aws_security_group.cfd_sg.id]

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price          = "1.00"
      spot_instance_type = "one-time"
    }
  }

  root_block_device {
    volume_size           = 20
    delete_on_termination = true
  }

  tags = { Name = "CFD-Spot-Workstation" }
}

resource "aws_volume_attachment" "ebs_att" {
  device_name  = "/dev/sdf"
  volume_id    = aws_ebs_volume.sim_data.id
  instance_id  = aws_instance.cfd_workstation.id
  force_detach = true
}

output "workstation_public_ip" {
  value = aws_instance.cfd_workstation.public_ip
}