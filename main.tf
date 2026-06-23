provider "aws" {
  region = "af-south-1"
}

# --- Core VPC Foundation ---
resource "aws_vpc" "main" {
  cidr_block           = "192.168.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "LocalFlowEgressVPC" }
}

resource "aws_subnet" "regional_transit_subnet" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "192.168.0.0/24"
  availability_zone = "af-south-1a"
  tags              = { Name = "RegionalTransitSubnet" }
}

resource "aws_subnet" "route_server_subnet_1" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.1.0/24"
  availability_zone       = "af-south-1-los-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "LagosLocalZoneSubnet-1" }
}

resource "aws_subnet" "route_server_subnet_2" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "192.168.2.0/24"
  availability_zone       = "af-south-1-los-1a"
  map_public_ip_on_launch = true
  tags                    = { Name = "LagosLocalZoneSubnet-2" }
}

# --- Internet Access ---
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "LocalFlowIGW" }
}

resource "aws_route_table" "public_rt" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  route {
    cidr_block         = "10.10.10.0/24"
    transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  }
  tags = { Name = "PublicRouteTable" }
}

resource "aws_route_table_association" "public_assoc_1" {
  subnet_id      = aws_subnet.route_server_subnet_1.id
  route_table_id = aws_route_table.public_rt.id
}

resource "aws_route_table_association" "public_assoc_2" {
  subnet_id      = aws_subnet.route_server_subnet_2.id
  route_table_id = aws_route_table.public_rt.id
}

# --- Transit Gateway Infrastructure ---
resource "aws_ec2_transit_gateway" "tgw" {
  transit_gateway_cidr_blocks = ["10.10.10.0/24"]
  tags                        = { Name = "LocalFlowTGW" }
}

resource "aws_ec2_transit_gateway_vpc_attachment" "tgw_attachment" {
  subnet_ids         = [aws_subnet.regional_transit_subnet.id]
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
  vpc_id             = aws_vpc.main.id
}

resource "aws_ec2_transit_gateway_route_table" "tgw_rt" {
  transit_gateway_id = aws_ec2_transit_gateway.tgw.id
}

resource "aws_ec2_transit_gateway_connect" "tgw_connect" {
  transit_gateway_id      = aws_ec2_transit_gateway.tgw.id
  transport_attachment_id = aws_ec2_transit_gateway_vpc_attachment.tgw_attachment.id
}

resource "aws_ec2_transit_gateway_connect_peer" "peer" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.tgw_connect.id
  peer_address                  = "192.168.1.5"
  inside_cidr_blocks            = ["169.254.100.0/29"]
}

resource "aws_ec2_transit_gateway_connect_peer" "peer_2" {
  transit_gateway_attachment_id = aws_ec2_transit_gateway_connect.tgw_connect.id
  peer_address                  = "192.168.2.5"
  inside_cidr_blocks            = ["169.254.100.8/29"]
}

# --- Security & Keys ---
resource "aws_security_group" "nat_sg" {
  name        = "nat_sg"
  description = "Allow BGP, GRE, and internal traffic"
  vpc_id      = aws_vpc.main.id
  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["192.168.0.0/16", "10.10.10.0/24"]
  }
  ingress {
    from_port   = 22
    to_port     = 22
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

resource "aws_key_pair" "nat_key" {
  key_name   = "localflow-nat-key"
  public_key = file("${path.module}/localflow-key.pub")
}

data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]
  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

# --- NAT Appliance 1 ---
resource "aws_instance" "nat_1" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "m5.xlarge"
  subnet_id              = aws_subnet.route_server_subnet_1.id
  private_ip             = "192.168.1.5"
  key_name               = aws_key_pair.nat_key.key_name
  vpc_security_group_ids = [aws_security_group.nat_sg.id]
  source_dest_check      = false
  tags                   = { Name = "NAT-Appliance-1" }
  
  lifecycle {
    ignore_changes = [ami]
  }

  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  user_data              = <<-EOF
              #!/bin/bash
              sysctl -w net.ipv4.ip_forward=1
              echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
              iptables -t nat -A POSTROUTING ! -d 192.168.0.0/16 -j MASQUERADE
              EOF
}

# --- NAT Appliance 2 ---
resource "aws_instance" "nat_2" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = "m5.xlarge"
  subnet_id              = aws_subnet.route_server_subnet_2.id
  private_ip             = "192.168.2.5"
  key_name               = aws_key_pair.nat_key.key_name
  vpc_security_group_ids = [aws_security_group.nat_sg.id]
  source_dest_check      = false
  tags                   = { Name = "NAT-Appliance-2" }
  
  root_block_device {
    volume_type = "gp2"
    volume_size = 8
  }

  timeouts {
    create = "5m"
  }

  user_data              = <<-EOF
              #!/bin/bash
              sysctl -w net.ipv4.ip_forward=1
              echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
              iptables -t nat -A POSTROUTING ! -d 192.168.0.0/16 -j MASQUERADE
              EOF
}

# --- Elastic IP ---
resource "aws_eip" "nat_eip_1" {
  instance             = aws_instance.nat_1.id
  domain               = "vpc"
  network_border_group = "af-south-1-los-1" 
  tags                 = { Name = "NAT-Appliance-1-EIP" }

  lifecycle {
    prevent_destroy = true
  }
}