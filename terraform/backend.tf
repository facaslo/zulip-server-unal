# Estado remoto en Google Cloud Storage. El bucket lo crea
# terraform/bootstrap y se pasa al inicializar, para no dejar el
# nombre fijo en el código:
#
#   terraform init -backend-config=backend.hcl
#
# El backend GCS bloquea el estado durante cada operación, así
# que dos personas (o el pipeline) no pueden aplicar a la vez.
terraform {
  backend "gcs" {
    prefix = "zulip/gke"
  }
}
