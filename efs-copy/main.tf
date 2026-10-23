terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# Provider padrão: Conta B (Destino)
provider "aws" {
  region = var.aws_region
  profile = "ringgo-prd" 
}

# Provider secundário: Conta A (Origem)
# Configure via profile correspondente no ~/.aws/credentials ou via assume_role
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
    Name        = "vpc-transitoria-migracao-efs"
    Environment = "Migration-Temporary"
  }
}

resource "aws_subnet" "transient_subnet" {
  vpc_id                  = aws_vpc.transient_vpc.id
  cidr_block              = var.transient_subnet_cidr
  availability_zone       = var.transient_az
  map_public_ip_on_launch = true

  tags = {
    Name = "subnet-transitoria-datasync"
  }
}

resource "aws_route_table" "transient_rt" {
  vpc_id = aws_vpc.transient_vpc.id

  tags = {
    Name = "rt-transitoria-datasync"
  }
}

resource "aws_route_table_association" "transient_assoc" {
  subnet_id      = aws_subnet.transient_subnet.id
  route_table_id = aws_route_table.transient_rt.id
}

# Internet Gateway para comunicação e ativação do DataSync Agent
resource "aws_internet_gateway" "transient_igw" {
  vpc_id = aws_vpc.transient_vpc.id

  tags = {
    Name = "igw-transitoria-datasync"
  }
}

resource "aws_route" "route_to_internet" {
  route_table_id         = aws_route_table.transient_rt.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.transient_igw.id
}

# ==============================================================================
# 2. VPC PEERING (CONTA B -> CONTA A)
# ==============================================================================

# Cria a solicitação a partir da Conta B
resource "aws_vpc_peering_connection" "peering_migracao" {
  vpc_id        = aws_vpc.transient_vpc.id
  peer_vpc_id   = var.account_a_vpc_id
  peer_owner_id = var.account_a_id
  peer_region   = var.aws_region
  auto_accept   = false

  tags = {
    Name = "peering-transitoria-contaB-para-contaA"
  }
}

# Aceita a solicitação na Conta A
resource "aws_vpc_peering_connection_accepter" "peer_accept" {
  provider                  = aws.origem
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_migracao.id
  auto_accept               = true

  tags = {
    Name = "peering-transitoria-aceite-contaA"
  }
}

# ==============================================================================
# 3. ROTAS (CONTA B E CONTA A)
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
# 4. SECURITY GROUP PARA O DATASYNC (CONTA B)
# ==============================================================================

resource "aws_security_group" "datasync_sg" {
  name        = "datasync-migracao-efs"
  description = "Security Group para interfaces de rede do AWS DataSync"
  vpc_id      = aws_vpc.transient_vpc.id

  # Libera saída NFS para o EFS da Conta A e Conta B
  egress {
    description = "Allow NFS outbound to EFS"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.account_a_vpc_cidr, "0.0.0.0/0"]
  }

  tags = {
    Name = "sg-datasync-migracao"
  }
}

# 1. Variável com o ID da sua VPC Definitiva e Route Table
variable "target_vpc_id" {
  description = "VPC ID da VPC Definitiva na Conta B onde o EFS reside"
  type        = string
  default     = "vpc-0702cf649d7d41c9a" 
}

variable "target_vpc_cidr" {
  description = "CIDR da VPC Definitiva (ex: 10.0.0.0/16)"
  type        = string
  default     = "10.100.0.0/16"
}

variable "target_route_table_id" {
  description = "Route Table ID da subnet do EFS na VPC Definitiva"
  type        = string
  default     = "rtb-0d1ccf76c8afbc49c"
}

# 2. Conexão de VPC Peering Local (Mesma Conta)
resource "aws_vpc_peering_connection" "peering_local_transient_to_target" {
  vpc_id      = aws_vpc.transient_vpc.id
  peer_vpc_id = var.target_vpc_id
  auto_accept = true # Na mesma conta e região aceita de forma automática

  tags = {
    Name = "peering-local-transitoria-para-definitiva"
  }
}

# 3. Rota na VPC Transitória -> VPC Definitiva
resource "aws_route" "route_transient_to_target" {
  route_table_id            = aws_route_table.transient_rt.id
  destination_cidr_block    = var.target_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_local_transient_to_target.id
}

# 4. Rota de retorno na VPC Definitiva -> VPC Transitória
resource "aws_route" "route_target_to_transient" {
  route_table_id            = var.target_route_table_id
  destination_cidr_block    = var.transient_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.peering_local_transient_to_target.id
}

# ==============================================================================
# 5. DATASYNC AGENT (CONTA B)
# ==============================================================================

resource "aws_security_group" "datasync_agent_sg" {
  name        = "datasync-agent-migracao"
  description = "Security Group para o AWS DataSync Agent"
  vpc_id      = aws_vpc.transient_vpc.id

  # Inbound HTTP (80) para ativação do Agent
  ingress {
    description = "HTTP para ativacao do DataSync Agent"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Outbound HTTPS (443) para o serviço AWS DataSync
  egress {
    description = "HTTPS para o servico AWS DataSync"
    from_port   = 443
    to_port     = 443
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

  # Outbound NFS (2049) para Conta A e Conta B
  egress {
    description = "NFS para EFS Conta A e Conta B"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.account_a_vpc_cidr, var.target_vpc_cidr]
  }

  tags = {
    Name = "sg-datasync-agent"
  }
}

data "aws_ssm_parameter" "datasync_ami" {
  name = "/aws/service/datasync/ami"
}

resource "aws_instance" "datasync_agent" {
  ami                         = data.aws_ssm_parameter.datasync_ami.value
  instance_type               = "m5.2xlarge"
  subnet_id                   = aws_subnet.transient_subnet.id
  vpc_security_group_ids      = [aws_security_group.datasync_agent_sg.id]
  associate_public_ip_address = true
  key_name                    = "ringgo-prd"

  tags = {
    Name        = "datasync-agent-efs-migration"
    Environment = "Migration-Temporary"
  }
}