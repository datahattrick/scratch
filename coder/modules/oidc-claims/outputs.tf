output "claims" {
  value       = local.claims
  description = "All claims, as the IdP sent them. {} when there is no token or userinfo was not fetched."
}

output "lists" {
  value       = local.lists
  description = "Claim name => list(string), for every claim that is a scalar or a list of scalars. Use lookup(module.oidc.lists, \"groups\", [])."
}

output "incomplete" {
  value       = local.incomplete
  description = "Names of claims the IdP left out (Entra ID group overage: [\"groups\"])."
}

output "has_token" {
  value       = local.has_token
  description = "False for password-login users, import, dry-run and the dashboard parameter preview."
}

output "is_import" {
  value       = local.is_import
  description = "True during template import or dry-run, where no owner or token exists."
}
