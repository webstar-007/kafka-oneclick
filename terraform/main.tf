# ============================================================================
# Everything Terraform builds on AWS, in reading order:
#   1. SSH key   2. Network   3. Firewalls   4. Servers   5. Ansible inventory
# ============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

# Zones that offer our server type (for example us-east-1e does not offer t3.small)
data "aws_ec2_instance_type_offerings" "broker" {
  location_type = "availability-zone"

  filter {
    name   = "instance-type"
    values = [var.broker_instance_type]
  }
}

# Latest Ubuntu 22.04 image published by Canonical
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

locals {
  # one zone per broker
  azs = slice(
    sort(
      tolist(
        setintersection(
          toset(data.aws_availability_zones.available.names),
          toset(data.aws_ec2_instance_type_offerings.broker.locations)
        )
      )
    ),
    0,
    var.broker_count
  )

  tags = {
    Project = var.project
  }
}

# ============================================================================
# 1. SSH key: created here, saved in keys/, never committed to Git
# ============================================================================

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "this" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "local_sensitive_file" "pem" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/../keys/${var.project}.pem"
  file_permission = "0600"
}

# ============================================================================
# 2. Network: one VPC, one subnet per availability zone
# ============================================================================

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = merge(local.tags, {
    Name = "${var.project}-vpc"
  })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = merge(local.tags, {
    Name = "${var.project}-igw"
  })
}

resource "aws_subnet" "this" {
  count                   = var.broker_count
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.0.${count.index}.0/24"
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true

  tags = merge(local.tags, {
    Name = "${var.project}-subnet-${count.index + 1}"
  })
}

resource "aws_route_table" "this" {
  vpc_id = aws_vpc.this.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }

  tags = merge(local.tags, {
    Name = "${var.project}-rt"
  })
}

resource "aws_route_table_association" "this" {
  count          = var.broker_count
  subnet_id      = aws_subnet.this[count.index].id
  route_table_id = aws_route_table.this.id
}

# ============================================================================
# 3. Firewalls (security groups)
# ============================================================================

resource "aws_security_group" "bastion" {
  name        = "${var.project}-bastion"
  description = "SSH access and Kafka UI on the bastion"
  vpc_id      = aws_vpc.this.id

  # SSH access
  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  # Kafka UI access from your allowed IP/CIDR
  ingress {
    description = "Kafka UI access"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.allowed_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.project}-bastion-sg"
  })
}

resource "aws_security_group" "broker" {
  name        = "${var.project}-broker"
  description = "Kafka brokers"
  vpc_id      = aws_vpc.this.id

  ingress {
    description     = "SSH only from the bastion"
    from_port       = 22
    to_port         = 22
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description = "Brokers talk to each other"
    from_port   = 9092
    to_port     = 9093
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Kafka clients on the bastion (producer, consumer, Kafka UI)"
    from_port       = 9092
    to_port         = 9092
    protocol        = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${var.project}-broker-sg"
  })
}

# ============================================================================
# 4. Servers
# ============================================================================

resource "aws_instance" "bastion" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.bastion_instance_type
  subnet_id              = aws_subnet.this[0].id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.bastion.id]

  tags = merge(local.tags, {
    Name = "${var.project}-bastion"
    Role = "bastion"
  })
}

resource "aws_instance" "broker" {
  count                  = var.broker_count
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.broker_instance_type
  subnet_id              = aws_subnet.this[count.index].id
  key_name               = aws_key_pair.this.key_name
  vpc_security_group_ids = [aws_security_group.broker.id]

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = merge(local.tags, {
    Name   = "${var.project}-broker-${count.index + 1}"
    Role   = "broker"
    NodeId = tostring(count.index + 1)
  })
}

# ============================================================================
# 5. Ansible inventory: written from the real IPs
# ============================================================================

resource "local_file" "inventory" {
  filename = "${path.module}/../ansible/inventory.ini"

  content = templatefile("${path.module}/inventory.tftpl", {
    bastion_ip = aws_instance.bastion.public_ip
    key_path   = abspath(local_sensitive_file.pem.filename)
    broker_ips = aws_instance.broker[*].private_ip
  })
}