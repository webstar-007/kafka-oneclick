output "bastion_public_ip" {
  value = aws_instance.bastion.public_ip
}

output "broker_private_ips" {
  value = aws_instance.broker[*].private_ip
}
