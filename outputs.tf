output "workstation_public_ip" {
  description = "The Public IP address of your CFD Workstation. Copy this!"
  value       = aws_instance.cfd_workstation.public_ip
}

output "ssh_connection_string" {
  description = "Command to SSH into the machine (for advanced users)."
  value       = "ssh -i ${var.key_name}.pem ubuntu@${aws_instance.cfd_workstation.public_ip}"
}

output "instance_id" {
  description = "The ID of the workstation (useful for Pausing/Stopping via CLI)."
  value       = aws_instance.cfd_workstation.id
}