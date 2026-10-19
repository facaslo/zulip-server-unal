output "state_bucket" {
  description = "Bucket para backend.hcl del stack principal."
  value       = google_storage_bucket.tfstate.name
}

output "deployer_service_account" {
  description = "Cuenta de servicio que usa GitHub Actions (service_account en google-github-actions/auth)."
  value       = google_service_account.deployer.email
}

output "workload_identity_provider" {
  description = "Proveedor WIF (workload_identity_provider en google-github-actions/auth)."
  value       = google_iam_workload_identity_pool_provider.github.name
}
