output "transient_vpc_id" {
  description = "ID da VPC Transitória criada na Conta B"
  value       = aws_vpc.transient_vpc.id
}

output "transient_subnet_id" {
  description = "ID da Subnet da VPC Transitória"
  value       = aws_subnet.transient_subnet.id
}

output "migrator_security_group_id" {
  description = "ID do Security Group da EC2 de migração"
  value       = aws_security_group.redis_migrator_sg.id
}

output "peering_cross_account_id" {
  description = "ID do VPC Peering estabelecido entre Conta B (Transitória) e Conta A"
  value       = aws_vpc_peering_connection.peering_migracao.id
}

output "peering_local_target_id" {
  description = "ID do VPC Peering local entre VPC Transitória e VPC Definitiva na Conta B"
  value       = aws_vpc_peering_connection.peering_local_transient_to_target.id
}

output "migrator_instance_id" {
  description = "ID da instância EC2 worker de migração"
  value       = aws_instance.redis_migrator.id
}

output "migrator_instance_public_ip" {
  description = "IP público da instância EC2 de migração"
  value       = aws_instance.redis_migrator.public_ip
}

output "ssm_connect_command" {
  description = "Comando para conectar instantaneamente na instância via AWS Session Manager (sem precisar de chave SSH)"
  value       = "aws ssm start-session --target ${aws_instance.redis_migrator.id} --profile ringgo-prd --region ${var.aws_region}"
}