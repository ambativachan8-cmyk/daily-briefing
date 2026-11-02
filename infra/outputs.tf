output "public_ip" {
  value = aws_eip.vm.public_ip
}

output "public_hostname" {
  description = "Free wildcard DNS name usable by Caddy for automatic HTTPS."
  value       = "${replace(aws_eip.vm.public_ip, ".", "-")}.sslip.io"
}

output "ssh" {
  value = "ssh ubuntu@${aws_eip.vm.public_ip}"
}

output "agent_dashboards_tunnel" {
  description = "Dashboards stay on the VM's loopback; reach them through this tunnel."
  value       = "ssh -N -L 18789:127.0.0.1:18789 -L 9119:127.0.0.1:9119 ubuntu@${aws_eip.vm.public_ip}"
}
