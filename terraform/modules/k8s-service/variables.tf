variable "name" {
  description = "Nombre del componente; se usa para el Deployment, el Service y su nombre DNS."
  type        = string
}

variable "namespace" {
  description = "Namespace de Kubernetes donde se despliega."
  type        = string
}

variable "image" {
  description = "Imagen del contenedor."
  type        = string
}

variable "command" {
  description = "Reemplaza el ENTRYPOINT de la imagen (equivale a entrypoint en compose)."
  type        = list(string)
  default     = null
}

variable "args" {
  description = "Reemplaza el CMD de la imagen (equivale a command en compose)."
  type        = list(string)
  default     = null
}

variable "port" {
  description = "Puerto TCP que expone el contenedor y el Service."
  type        = number
}

variable "env" {
  description = "Variables de entorno no sensibles."
  type        = map(string)
  default     = {}
}

variable "secret_env" {
  description = "Variables de entorno sensibles; se guardan en un Secret de Kubernetes."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "volume" {
  description = "Volumen persistente opcional (equivale a volumes en compose)."
  type = object({
    size       = string
    mount_path = string
  })
  default = null
}

variable "init_args" {
  description = "Si se define, corre un init container con la misma imagen y estos argumentos antes del contenedor principal."
  type        = list(string)
  default     = null
}

variable "probe" {
  description = "Healthcheck del contenedor: exactamente uno de exec, tcp o http_path."
  type = object({
    exec                      = optional(list(string))
    tcp                       = optional(bool, false)
    http_path                 = optional(string)
    http_scheme               = optional(string, "HTTP")
    startup_failure_threshold = optional(number, 30)
  })

  validation {
    condition = length(compact([
      var.probe.exec == null ? "" : "exec",
      var.probe.tcp ? "tcp" : "",
      var.probe.http_path == null ? "" : "http",
    ])) == 1
    error_message = "probe debe definir exactamente uno de: exec, tcp, http_path."
  }
}

variable "resources" {
  description = "Requests y limits de CPU/memoria del contenedor."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
}

variable "service_type" {
  description = "Tipo de Service: ClusterIP (interno) o LoadBalancer (público)."
  type        = string
  default     = "ClusterIP"

  validation {
    condition     = contains(["ClusterIP", "LoadBalancer"], var.service_type)
    error_message = "service_type debe ser ClusterIP o LoadBalancer."
  }
}

variable "load_balancer_ip" {
  description = "IP estática para un Service de tipo LoadBalancer."
  type        = string
  default     = null
}

variable "allowed_clients" {
  description = "Componentes (label app) que pueden conectarse. null = sin NetworkPolicy."
  type        = list(string)
  default     = null
}

variable "wait_for_rollout" {
  description = "Si Terraform espera a que el Deployment quede disponible."
  type        = bool
  default     = true
}

variable "labels" {
  description = "Etiquetas comunes de Kubernetes."
  type        = map(string)
  default     = {}
}
