variable "name" {
  description = "Nombre del Deployment/Service (y nombre DNS interno resultante)."
  type        = string
  default     = "toxiproxy"
}

variable "namespace" {
  description = "Namespace de Kubernetes donde corre Zulip/RabbitMQ."
  type        = string
}

variable "image" {
  description = "Imagen de Toxiproxy, fijada a una versión exacta (nunca :latest)."
  type        = string
  default     = "ghcr.io/shopify/toxiproxy:2.13.0"
}

variable "proxy_port" {
  description = "Puerto que imita a RabbitMQ (AMQP); Zulip se conecta aquí."
  type        = number
  default     = 5672
}

variable "admin_port" {
  description = "Puerto de la API HTTP de administración de Toxiproxy (crear/editar toxics)."
  type        = number
  default     = 8474
}

variable "upstream_host" {
  description = "Host real de RabbitMQ al que Toxiproxy reenvía el tráfico."
  type        = string
}

variable "upstream_port" {
  description = "Puerto real de RabbitMQ."
  type        = number
  default     = 5672
}

variable "allowed_proxy_clients" {
  description = "Labels 'app' de los Pods que pueden conectarse al puerto proxy (5672)."
  type        = list(string)
  default     = ["zulip"]
}

variable "labels" {
  description = "Etiquetas comunes de Kubernetes."
  type        = map(string)
  default     = {}
}

variable "resources" {
  description = "Requests/limits del contenedor. Toxiproxy es liviano; valores pequeños bastan."
  type = object({
    requests = object({ cpu = string, memory = string })
    limits   = object({ memory = string })
  })
  default = {
    requests = { cpu = "50m", memory = "32Mi" }
    limits   = { memory = "128Mi" }
  }
}
