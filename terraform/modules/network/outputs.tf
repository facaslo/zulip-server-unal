output "network_id" {
  description = "ID de la VPC."
  value       = google_compute_network.this.id
}

output "network_name" {
  description = "Nombre de la VPC."
  value       = google_compute_network.this.name
}

output "subnet_name" {
  description = "Nombre de la subred de los nodos."
  value       = google_compute_subnetwork.this.name
}

output "pods_range_name" {
  description = "Nombre del rango secundario de Pods."
  value       = google_compute_subnetwork.this.secondary_ip_range[0].range_name
}

output "services_range_name" {
  description = "Nombre del rango secundario de Services."
  value       = google_compute_subnetwork.this.secondary_ip_range[1].range_name
}

output "ingress_ip" {
  description = "IP pública estática reservada para Zulip."
  value       = google_compute_address.ingress.address
}
