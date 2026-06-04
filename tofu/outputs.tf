data "linode_instance_networking" "this" {
  linode_id = linode_instance.this.id
}

output "instance_id" {
  description = "Linode instance id."
  value       = linode_instance.this.id
}

output "ip_address" {
  description = "Public IPv4 address."
  value       = try(data.linode_instance_networking.this.ipv4[0].public[0].address, null)
}

output "private_ip_address" {
  description = "Private IPv4 address (only when private_ip = true)."
  value       = try(data.linode_instance_networking.this.ipv4[0].private[0].address, null)
}

output "ssh_command" {
  description = "Convenience SSH command (key auth as the core user)."
  value       = "ssh core@${try(data.linode_instance_networking.this.ipv4[0].public[0].address, "<ip>")}"
}

output "kubeconfig_hint" {
  description = "Command to fetch the k3s kubeconfig after a CLUSTER=k3s deploy."
  value       = "make kubeconfig   # fetches /etc/rancher/k3s/k3s.yaml and writes ./kubeconfig"
}
