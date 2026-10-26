aws_region = "sa-east-1"

# Range descartável para a VPC temporária (não pode sobrepor a VPC da Conta A nem a Definitiva)
transient_vpc_cidr    = "172.31.0.0/24"
transient_subnet_cidr = "172.31.0.0/26"
transient_az          = "sa-east-1a"

# Dados reais da sua Conta A (Origem - onnibank)
account_a_id             = "352187878218"
account_a_vpc_id         = "vpc-09033f0343de5abe1"
account_a_vpc_cidr       = "10.100.12.0/22"
account_a_route_table_id = "rtb-0a29b4cc7c7f0230f"

# Dados reais da sua Conta B (Destino - ringgo-prd)
target_vpc_id         = "vpc-0702cf649d7d41c9a"
target_vpc_cidr       = "10.100.0.0/16"
target_route_table_id = "rtb-0d1ccf76c8afbc49c"

# Configurações do Worker
redis_port    = 6379
instance_type = "t3.micro"
key_name      = "ringgo-prd"
