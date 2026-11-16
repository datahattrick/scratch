output "organisation" {
  value       = local.org
  description = "The workspace's organisation, or \"none\"."
}

output "has_org" {
  value       = local.has_org
  description = "False when the organisation is \"none\". Known at plan; use it in count."
}

output "namespace" {
  value       = terraform_data.namespace.input
  description = "The pinned namespace."
}

output "node_selector" {
  value       = var.node_label_pattern == "" ? {} : { (replace(var.node_label_pattern, "<org>", local.org)) = "true" }
  description = "Node selector for the organisation's nodes, or {}."
}

output "labels" {
  value       = var.org_label_key == "" ? {} : { (var.org_label_key) = local.org }
  description = "Labels to merge into the template's resources."
}

output "user_organisations" {
  value       = local.orgs
  description = "var.organisations after normalising and filtering, supported or not."
}
