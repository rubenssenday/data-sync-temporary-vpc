variable "aws_region" {
  description = "Região AWS onde os recursos estão alocados"
  type        = string
  default     = "sa-east-1"
}

# --- Conta B (Destino - VPC Temporária de Migração) ---
variable "transient_vpc_cidr" {
  description = "Bloco CIDR da VPC transitória (deve ser diferente do CIDR da Conta A e da VPC Definitiva)"
  type        = string
  default     = "172.31.0.0/24"
}

variable "transient_subnet_cidr" {
  description = "Subnet para o worker de migração na VPC transitória"
  type        = string
  default     = "172.31.0.0/26"
}

variable "transient_az" {
  description = "Availability Zone da subnet transitória"
  type        = string
  default     = "sa-east-1a"
}

# --- Conta A (Origem - Onde reside o ElastiCache de Origem) ---
variable "account_a_id" {
  description = "ID da Conta A (Origem)"
  type        = string
}

variable "account_a_vpc_id" {
  description = "VPC ID da Conta A onde reside o Redis de origem"
  type        = string
}

variable "account_a_vpc_cidr" {
  description = "CIDR da VPC da Conta A (ex: 10.100.12.0/22)"
  type        = string
}

variable "account_a_route_table_id" {
  description = "Route Table ID da subnet do ElastiCache na Conta A para retorno de rota"
  type        = string
}

# --- Conta B (Destino - Onde reside o ElastiCache Definitivo) ---
variable "target_vpc_id" {
  description = "VPC ID da VPC Definitiva na Conta B onde o Redis de destino reside"
  type        = string
}

variable "target_vpc_cidr" {
  description = "CIDR da VPC Definitiva na Conta B (ex: 10.100.0.0/16)"
  type        = string
}

variable "target_route_table_id" {
  description = "Route Table ID da subnet do Redis na VPC Definitiva"
  type        = string
}

# --- Configurações do Worker de Migração e Redis ---
variable "redis_port" {
  description = "Porta TCP do Redis/ElastiCache"
  type        = number
  default     = 6379
}

variable "instance_type" {
  description = "Tipo de instância EC2 para o worker de migração (processamento e rede)"
  type        = string
  default     = "t3.large"
}

variable "key_name" {
  description = "Nome opcional do Key Pair caso deseje SSH direto (opcional, SSM Session Manager recomendado)"
  type        = string
  default     = null
}