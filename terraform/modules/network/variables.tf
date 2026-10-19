variable "project_id" {
  description = "ID del proyecto de GCP."
  type        = string
}

variable "name" {
  description = "Prefijo para nombrar los recursos de red."
  type        = string
}

variable "region" {
  description = "Región de GCP donde se crea la subred."
  type        = string
}

variable "subnet_cidr" {
  description = "Rango primario de la subred (IPs de los nodos)."
  type        = string
}

variable "pods_cidr" {
  description = "Rango secundario para las IPs de los Pods."
  type        = string
}

variable "services_cidr" {
  description = "Rango secundario para las IPs de los Services."
  type        = string
}
