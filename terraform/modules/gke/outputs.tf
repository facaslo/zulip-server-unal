output "cluster_name" {
  description = "Nombre del clúster GKE."
  value       = google_container_cluster.this.name
}

output "endpoint" {
  description = "Endpoint de la API de Kubernetes."
  value       = google_container_cluster.this.endpoint
}

output "ca_certificate" {
  description = "Certificado de la CA del clúster (base64)."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
  sensitive   = true
}

output "node_service_account" {
  description = "Correo de la cuenta de servicio de los nodos."
  value       = google_service_account.nodes.email
}
