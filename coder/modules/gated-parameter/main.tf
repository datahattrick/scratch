# A workspace parameter whose options can each require an IdP group.
#
# The dashboard parameter preview has no OIDC token, so every user sees every
# option. The module only reports whether the chosen option is allowed; the
# template decides where to enforce it (a precondition on a start-only
# resource, so stop and delete never need the group).
#
# Files: main.tf (providers, data sources), variables.tf, locals.tf,
# outputs.tf.

terraform {
  required_providers {
    coder = { source = "coder/coder" }
  }
}

data "coder_parameter" "this" {
  name         = var.name
  display_name = var.display_name
  description  = var.description
  type         = "string"
  default      = var.default
  mutable      = var.mutable

  dynamic "option" {
    for_each = var.options
    content {
      value       = option.key
      name        = option.value.name
      description = option.value.required_group == null ? option.value.description : trimspace("${option.value.description} Requires ${option.value.required_group}.")
    }
  }
}
