# ============================================================
# Credenciales internas generadas por Terraform.
# Reemplazan los "change_me" de los .env de deploy/: nadie las
# escribe a mano ni quedan en el repositorio.
# ============================================================
resource "random_password" "this" {
  for_each = var.secret_lengths

  length = each.value
  # Sin caracteres especiales: algunas de estas contraseñas se
  # interpolan en archivos de configuración (p. ej. la base SASL
  # de Memcached usa ":" como separador).
  special = false
}

# Copia en Secret Manager para que los operadores puedan
# consultarlas (con IAM y auditoría) sin leer el estado.
resource "google_secret_manager_secret" "this" {
  for_each = var.secret_lengths

  project   = var.project_id
  secret_id = "${var.name}-${replace(each.key, "_", "-")}"
  labels    = var.labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "this" {
  for_each = var.secret_lengths

  secret      = google_secret_manager_secret.this[each.key].id
  secret_data = random_password.this[each.key].result
}
