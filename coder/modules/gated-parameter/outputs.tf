output "value" {
  value = data.coder_parameter.this.value
}

output "allowed" {
  value = local.allowed
}

output "error_message" {
  value = "The ${local.option.name} option of '${var.display_name}' requires the '${coalesce(local.required_group, "-")}' group (your groups: ${jsonencode(var.user_groups)}). Choose another option, or ask an admin to add you to the group.${local.overage_note}"
}
