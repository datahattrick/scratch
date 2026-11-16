locals {
  option         = var.options[data.coder_parameter.this.value]
  required_group = local.option.required_group
  allowed        = local.required_group == null || contains(var.user_groups, coalesce(local.required_group, "-"))
  overage_note   = var.groups_incomplete ? " Your SSO provider sent only some of your groups because you are in too many; ask an admin to limit the groups sent to Coder." : ""
}
