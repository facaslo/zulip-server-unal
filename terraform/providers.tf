# Sin bloque credentials: el proveedor usa Application Default
# Credentials (gcloud auth application-default login en local,
# Workload Identity Federation en GitHub Actions). Así nunca hay
# una llave JSON en el repositorio ni en el estado.
provider "google" {
  project = var.project_id
  region  = var.region
}

data "google_client_config" "current" {}

# Se autentica contra GKE con el token OAuth de corta duración de
# la identidad que ejecuta Terraform; no se genera kubeconfig.
provider "kubernetes" {
  host                   = "https://${module.gke.endpoint}"
  token                  = data.google_client_config.current.access_token
  cluster_ca_certificate = base64decode(module.gke.ca_certificate)
}
