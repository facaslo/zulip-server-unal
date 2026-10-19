output "values" {
  description = "Valores generados, por nombre de secreto."
  value       = { for name, password in random_password.this : name => password.result }
  sensitive   = true
}

output "secret_ids" {
  description = "IDs de los secretos en Secret Manager, por nombre."
  value       = { for name, secret in google_secret_manager_secret.this : name => secret.secret_id }
}
