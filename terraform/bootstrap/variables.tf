variable "project_id" {
  description = "ID del proyecto de GCP."
  type        = string
}

variable "region" {
  description = "Ubicación del bucket de estado."
  type        = string
  default     = "us-central1"
}

variable "github_repository" {
  description = "Repositorio (owner/nombre) autorizado a desplegar vía Workload Identity Federation."
  type        = string
  default     = "facaslo/zulip-server-unal"
}
