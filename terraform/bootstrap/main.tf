# ============================================================
# Bootstrap: recursos que deben existir ANTES del stack principal
# y que este no puede gestionar (su propio backend y la identidad
# con la que se ejecuta). Se aplica una sola vez por proyecto,
# con estado local, por alguien con rol Owner.
# ============================================================
resource "google_project_service" "this" {
  for_each = toset([
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "storage.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "serviceusage.googleapis.com",
  ])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ============================================================
# Bucket del estado remoto (terraform.tfstate)
# ============================================================
resource "google_storage_bucket" "tfstate" {
  project  = var.project_id
  name     = "${var.project_id}-tfstate"
  location = var.region

  # El estado contiene las contraseñas generadas: sin acceso
  # público, solo IAM a nivel de bucket (sin ACLs por objeto).
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  # Cada escritura del estado crea una versión: permite recuperar
  # el estado anterior si un apply lo corrompe.
  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 20
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = {
    app        = "zulip"
    managed-by = "terraform"
    purpose    = "terraform-state"
  }

  depends_on = [google_project_service.this]
}

# ============================================================
# Identidad de despliegue para GitHub Actions.
# Workload Identity Federation: GitHub emite un token OIDC por
# ejecución y GCP lo cambia por credenciales de corta duración de
# la cuenta de servicio. No existe ninguna llave JSON que filtrar.
# ============================================================
resource "google_service_account" "deployer" {
  project      = var.project_id
  account_id   = "terraform-deployer"
  display_name = "Terraform (GitHub Actions)"
}

# La cuenta que aplica Terraform tiene que poder crear la red, el
# clúster, la cuenta de servicio de los nodos y sus roles, por eso
# necesita roles de administración sobre esos servicios.
resource "google_project_iam_member" "deployer" {
  for_each = toset([
    "roles/compute.networkAdmin",
    "roles/container.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/secretmanager.admin",
    "roles/serviceusage.serviceUsageAdmin",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.deployer.email}"
}

# Acceso al estado limitado a este bucket (no a todo Storage).
resource "google_storage_bucket_iam_member" "deployer_state" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.deployer.email}"
}

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Solo los workflows de este repositorio pueden obtener tokens;
  # sin esta condición serviría cualquier repositorio de GitHub.
  attribute_condition = "assertion.repository == '${var.github_repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "deployer_wif" {
  service_account_id = google_service_account.deployer.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
