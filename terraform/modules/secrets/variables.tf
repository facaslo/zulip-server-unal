variable "project_id" {
  description = "ID del proyecto de GCP."
  type        = string
}

variable "name" {
  description = "Prefijo de los secretos en Secret Manager."
  type        = string
}

variable "secret_lengths" {
  description = "Secretos a generar: nombre => longitud de la contraseña."
  type        = map(number)
}

variable "labels" {
  description = "Etiquetas aplicadas a los secretos."
  type        = map(string)
}
