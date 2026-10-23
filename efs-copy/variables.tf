variable "aws_region" {
  description = "Região AWS onde os recursos estão alocados"
  type        = string
  default     = "us-east-1"
}

# --- Conta B (Destino - Onde criaremos a VPC temporária) ---
variable "transient_vpc_cidr" {
  description = "Bloco CIDR da VPC transitória (deve ser diferente do CIDR da Conta A)"
  type        = string
  default     = "172.31.0.0/24"
}

variable "transient_subnet_cidr" {
  description = "Subnet para o DataSync na VPC transitória"
  type        = string
  default     = "172.31.0.0/26"
}

variable "transient_az" {
  description = "Availability Zone da subnet (recomendado coincidir com a AZ do EFS de origem)"
  type        = string
  default     = "us-east-1a"
}

# --- Conta A (Origem - Infraestrutura existente) ---
variable "account_a_id" {
  description = "ID da Conta A (Origem)"
  type        = string
}

variable "account_a_vpc_id" {
  description = "VPC ID da Conta A onde reside o EFS de produção"
  type        = string
}

variable "account_a_vpc_cidr" {
  description = "CIDR da VPC da Conta A (ex: 10.0.0.0/16)"
  type        = string
}

variable "account_a_route_table_id" {
  description = "Route Table ID da subnet do EFS na Conta A para retorno de rota"
  type        = string
}