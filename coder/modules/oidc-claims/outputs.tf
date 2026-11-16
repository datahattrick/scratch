output "claims" {
  value       = local.claims
  sensitive   = true
  description = "All claims as a map. Empty when no token or not fetched."
}

output "organisations" {
  value       = local.orgs
  description = "Values of the organisations claim, normalised and filtered."
}

output "groups" {
  value       = local.groups
  description = "Group names from the groups claim, after group_pattern and group_names; case preserved."
}

output "groups_overage" {
  value       = local.groups_overage
  description = "True when the IdP left the groups out because there were too many (Entra ID group overage); groups is then incomplete."
}

output "is_import" {
  value       = local.is_import
  description = "True during template import or dry-run, where no owner or token exists."
}
