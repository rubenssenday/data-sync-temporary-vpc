output "transient_vpc_id" {
  description = "ID da VPC Transitória criada na Conta B"
  value       = aws_vpc.transient_vpc.id
}

output "transient_subnet_id" {
  description = "ID da Subnet para selecionar no Location do DataSync"
  value       = aws_subnet.transient_subnet.id
}

output "datasync_security_group_id" {
  description = "ID do Security Group para selecionar no Location do DataSync"
  value       = aws_security_group.datasync_sg.id
}

output "peering_connection_id" {
  description = "ID do VPC Peering estabelecido"
  value       = aws_vpc_peering_connection.peering_migracao.id
}

output "datasync_agent_public_ip" {
  description = "IP público do DataSync Agent para ativação"
  value       = aws_instance.datasync_agent.public_ip
}

output "datasync_agent_activation_url" {
  description = "URL para obter a ActivationKey do DataSync Agent"
  value       = "http://${aws_instance.datasync_agent.public_ip}/?gatewayType=SYNC&activationRegion=sa-east-1&endpointType=PUBLIC"
}