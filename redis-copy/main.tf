terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket  = "temporary-vpc-tfstate-741796255940"
    key     = "temporary-vpc/redis-migration/terraform.tfstate"
    region  = "sa-east-1"
    profile = "ringgo-prd"
    encrypt = true
  }
}

# Provider padrão: Conta B (Destino)
provider "aws" {
  region  = var.aws_region
  profile = "ringgo-prd"
}

# Provider secundário: Conta A (Origem)
provider "aws" {
  alias   = "origem"
  region  = var.aws_region
  profile = "onnibank"
}

# ==============================================================================
# 1. VPC TRANSITÓRIA (CONTA B)
# ==============================================================================

resource "aws_vpc" "transient_vpc" {
  cidr_block           = var.transient_vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name        = "vpc-transitoria-migracao-redis"
    Environment = "Migration-Temporary"
  }
}

resource "aws_subnet" "transient_subnet" {
  vpc_id                  = aws_vpc.transient_vpc.id
  cidr_block              = var.transient_subnet_cidr
  availability_zone       = var.transient_az
  map_public_ip_on_launch = true

  tags = {
    Name        = "subnet-transitoria-redis-migrator"
    Environment = "Migration-Temporary"
  }
}

resource "aws_route_table" "transient_rt" {
  vpc_id = aws_vpc.transient_vpc.id

  tags = {
    Name        = "rt-transitoria-redis-migrator"
    Environment = "Migration-Temporary"
  }
}

resource "aws_route_table_association" "transient_assoc" {
  subnet_id      = aws_subnet.transient_subnet.id
  route_table_id = aws_route_table.transient_rt.id
}

# Internet Gateway para comunicação externa, SSM e download de ferramentas
resource "aws_internet_gateway" "transient_igw" {
  vpc_id = aws_vpc.transient_vpc.id

  tags = {
    Name        = "igw-transitoria-redis-migrator"
    Environment = "Migration-Temporary"
  }
}

resource "aws_route" "route_to_internet" {
  route_table_id         = aws_route_table.transient_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.transient_igw.id
}

# ==============================================================================
# 2. VPC PEERING CROSS-ACCOUNT (CONTA B -> CONTA A)
# ==============================================================================

# Cria a solicitação a partir da Conta B
resource "aws_vpc_peering_connection" "peering_migracao" {
  vpc_id        = aws_vpc.transient_vpc.id
  peer_vpc_id   = var.account_a_vpc_id
  peer_owner_id = var.account_a_id
  peer_region   = var.aws_region
  auto_accept   = false

  tags = {
    Name        = "peering-transitoria-contaB-para-contaA"
    Environment = "Migration-Temporary"
  }
}

# Aceita a solicitação na Conta A
resource "aws_vpc_peering_connection_accepter" "peer_accept" {
  provider                  = aws.origem
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_migracao.id
  auto_accept               = true

  tags = {
    Name        = "peering-transitoria-aceite-contaA"
    Environment = "Migration-Temporary"
  }
}

# ==============================================================================
# 3. ROTAS CROSS-ACCOUNT (CONTA B E CONTA A)
# ==============================================================================

# Rota na Conta B (VPC Transitória -> VPC Origem Conta A)
resource "aws_route" "route_to_conta_a" {
  route_table_id            = aws_route_table.transient_rt.id
  destination_cidr_block    = var.account_a_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_migracao.id
}

# Rota de retorno na Conta A (VPC Origem Conta A -> VPC Transitória)
resource "aws_route" "route_to_conta_b" {
  provider                  = aws.origem
  route_table_id            = var.account_a_route_table_id
  destination_cidr_block    = var.transient_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_migracao.id
}

# ==============================================================================
# 4. VPC PEERING LOCAL (CONTA B TRANSITÓRIA -> CONTA B DEFINITIVA)
# ==============================================================================

resource "aws_vpc_peering_connection" "peering_local_transient_to_target" {
  vpc_id      = aws_vpc.transient_vpc.id
  peer_vpc_id = var.target_vpc_id
  auto_accept = true

  tags = {
    Name        = "peering-local-transitoria-para-definitiva"
    Environment = "Migration-Temporary"
  }
}

# Rota na VPC Transitória -> VPC Definitiva
resource "aws_route" "route_transient_to_target" {
  route_table_id            = aws_route_table.transient_rt.id
  destination_cidr_block    = var.target_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_local_transient_to_target.id
}

# Rota de retorno na VPC Definitiva -> VPC Transitória
resource "aws_route" "route_target_to_transient" {
  route_table_id            = var.target_route_table_id
  destination_cidr_block    = var.transient_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_local_transient_to_target.id
}

# ==============================================================================
# 5. IAM ROLE & INSTANCE PROFILE PARA AWS SSM (SESSION MANAGER)
# ==============================================================================

resource "aws_iam_role" "ssm_role" {
  name = "role-redis-migrator-ssm"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Environment = "Migration-Temporary"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_attach" {
  role       = aws_iam_role.ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm_profile" {
  name = "profile-redis-migrator-ssm"
  role = aws_iam_role.ssm_role.name
}

# ==============================================================================
# 6. SECURITY GROUP PARA O WORKER DE MIGRAÇÃO REDIS (CONTA B)
# ==============================================================================

resource "aws_security_group" "redis_migrator_sg" {
  name        = "redis-migrator-worker"
  description = "Security Group para a EC2 de migracao entre clusters Redis/ElastiCache"
  vpc_id      = aws_vpc.transient_vpc.id

  # Nenhum Inbound necessário! O acesso à EC2 é feito exclusivamente via AWS Systems
  # Manager (SSM Session Manager), que opera apenas com tráfego de saída (HTTPS 443).
  # Isso garante conformidade com Security Hub, GuardDuty e zero exposição na internet.

  # Outbound Redis para o ElastiCache da Conta A
  egress {
    description = "Redis TCP outbound para Conta A"
    from_port   = var.redis_port
    to_port     = var.redis_port
    protocol    = "tcp"
    cidr_blocks = [var.account_a_vpc_cidr]
  }

  # Outbound Redis para o ElastiCache da Conta B
  egress {
    description = "Redis TCP outbound para Conta B"
    from_port   = var.redis_port
    to_port     = var.redis_port
    protocol    = "tcp"
    cidr_blocks = [var.target_vpc_cidr]
  }

  # Outbound HTTPS (443) para SSM, repositórios e downloads
  egress {
    description = "HTTPS para AWS SSM e pacotes"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound HTTP (80) para pacotes e atualizações do SO
  egress {
    description = "HTTP para repositorios Linux"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound DNS (53)
  egress {
    description = "DNS UDP"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "DNS TCP"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name        = "sg-redis-migrator-worker"
    Environment = "Migration-Temporary"
  }
}

# ==============================================================================
# 7. EC2 INSTANCE: WORKER DE MIGRAÇÃO
# ==============================================================================

data "aws_ami" "amazon_linux_2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "redis_migrator" {
  ami                         = data.aws_ami.amazon_linux_2023.id
  instance_type               = var.instance_type
  subnet_id                   = aws_subnet.transient_subnet.id
  vpc_security_group_ids      = [aws_security_group.redis_migrator_sg.id]
  iam_instance_profile        = aws_iam_instance_profile.ssm_profile.name
  associate_public_ip_address = true
  key_name                    = var.key_name

  user_data = <<-EOF
              #!/bin/bash
              # Configurar 1GB de Swap para prevenir OOM (Out Of Memory)
              dd if=/dev/zero of=/swapfile bs=1M count=1024
              chmod 600 /swapfile
              mkswap /swapfile
              swapon /swapfile
              echo '/swapfile swap swap defaults 0 0' >> /etc/fstab

              # Atualização e utilitários básicos
              dnf update -y
              dnf install -y tmux htop jq wget tar unzip git redis6 docker java-17-amazon-corretto-headless

              # Inicializar Docker
              systemctl enable --now docker
              usermod -aG docker ec2-user

              # Link de conveniência para o redis-cli
              ln -sf /usr/bin/redis6-cli /usr/local/bin/redis-cli || true

              # Instalar Redis-Shake (versão estável mais recente via GitHub API)
              mkdir -p /opt/redis-shake
              cd /opt/redis-shake
              SHAKE_URL=$(curl -s https://api.github.com/repos/tair-opensource/RedisShake/releases/latest | jq -r '.assets[] | select(.name | contains("linux-amd64")) | .browser_download_url' | head -n 1)
              if [ -n "$SHAKE_URL" ]; then
                wget -q -O redis-shake.tar.gz "$SHAKE_URL"
                tar -xzf redis-shake.tar.gz || true
                find /opt/redis-shake -name "redis-shake" -exec cp {} /usr/local/bin/redis-shake \;
                chmod +x /usr/local/bin/redis-shake || true
              fi

              # Criar diretório de trabalho para migração
              mkdir -p /home/ec2-user/migration
              chown -R ec2-user:ec2-user /home/ec2-user/migration

              echo "Setup do Redis Migrator concluído com sucesso!" > /home/ec2-user/migration/STATUS.txt
              EOF

  tags = {
    Name        = "ec2-redis-migrator-worker"
    Environment = "Migration-Temporary"
  }
}
