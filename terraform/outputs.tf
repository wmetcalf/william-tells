output "url" {
  description = "Application URL"
  value       = "https://${var.hostname}"
}

output "alb_dns" {
  description = "ALB DNS name"
  value       = aws_lb.main.dns_name
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.mac.id
}

output "instance_public_ip" {
  description = "EC2 public IP (for SSH)"
  value       = aws_instance.mac.public_ip
}

output "dedicated_host_id" {
  description = "Dedicated host ID (24hr minimum billing)"
  value       = aws_ec2_host.mac.id
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i <your-key.pem> ec2-user@${aws_instance.mac.public_ip}"
}
