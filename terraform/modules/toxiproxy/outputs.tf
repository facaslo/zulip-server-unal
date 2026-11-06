output "host" {
  description = "Nombre DNS interno de Toxiproxy dentro del namespace."
  value       = kubernetes_service_v1.this.metadata[0].name
}

output "proxy_port" {
  description = "Puerto que imita a RabbitMQ (AMQP)."
  value       = var.proxy_port
}

output "admin_port" {
  description = "Puerto de la API HTTP de administración."
  value       = var.admin_port
}
