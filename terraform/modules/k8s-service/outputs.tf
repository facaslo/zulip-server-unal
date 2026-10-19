output "host" {
  description = "Nombre DNS interno del componente dentro del namespace."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "port" {
  description = "Puerto del Service."
  value       = var.port
}
