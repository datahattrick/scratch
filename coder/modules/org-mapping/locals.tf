locals {
  # From the claims.
  orgs      = module.claims.organisations # sorted
  is_import = module.claims.is_import
  starting  = data.coder_workspace.me.start_count == 1
  ns_for    = { for o in local.orgs : o => replace(var.namespace_pattern, "<org>", o) }

  # Supported: the namespace exists and, if namespace_org_label is set,
  # carries the organisation as that label's value.
  supported = [for o in local.orgs : o if
    data.kubernetes_namespace_v1.candidate[o].metadata[0].uid != "" &&
    (var.namespace_org_label == "" || lookup(coalesce(data.kubernetes_namespace_v1.candidate[o].metadata[0].labels, {}), var.namespace_org_label, "") == o)
  ]
  resolved = length(local.supported) > 0 ? local.supported[0] : "none"

  # Pinned.
  org     = terraform_data.org.input
  has_org = local.org != "none"

  # Error messages.
  contact = "If you believe this is an error, please contact ${var.support_contact}."

  no_org_error = (
    local.resolved != "none" ? "This workspace was created before your organisation was supported. Delete it and create a new one." :
    length(local.orgs) == 0 ? "Sorry, your account is not in any organisation. ${local.contact}" :
    "Sorry, ${length(local.orgs) == 1 ? "the '${local.orgs[0]}' organisation is" : "your organisations (${join(", ", local.orgs)}) are"} not supported at this time. ${local.contact}"
  )
  removed_error = "You are no longer in the '${local.org}' organisation (your organisations: ${jsonencode(local.orgs)}). ${local.contact}"
}
