# ------------------------------------------------------------------ claims

variable "claim_source" {
  type        = string
  default     = "userinfo"
  description = "\"userinfo\" (call the IdP's userinfo endpoint) or \"access_token\" (decode the JWT access token)."
}

variable "userinfo_url" {
  type        = string
  description = "The IdP's userinfo_endpoint. Required for claim_source = \"userinfo\"."
}

variable "organisations_claim" {
  type        = string
  default     = "organisations"
  description = "Name of the claim holding the user's organisations."
}

variable "organisation_name_regex" {
  type        = string
  default     = "^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$"
  description = "Claim values not matching this are ignored. The default keeps names usable in a namespace name."
}

variable "lowercase_organisations" {
  type        = bool
  default     = true
  description = "Lower-case claim values before matching."
}

variable "groups_claim" {
  type        = string
  default     = "groups"
  description = "Name of the claim holding the user's groups. Passed through as the `groups` output."
}

variable "group_pattern" {
  type        = string
  default     = "^/?(.+)$"
  description = "Regex extracting the group name from each value; see ../oidc-claims."
}

variable "group_names" {
  type        = map(string)
  default     = {}
  description = "Renames group values (e.g. Entra ID object IDs to names); see ../oidc-claims."
}

# ---------------------------------------------------------------- placement

variable "namespace_pattern" {
  type        = string
  default     = "<org>-workspaces"
  description = "Namespace for an organisation; <org> is replaced by its name. The organisation is supported only if this namespace exists."
  validation {
    condition     = strcontains(var.namespace_pattern, "<org>")
    error_message = "namespace_pattern must contain <org>."
  }
}

variable "namespace_org_label" {
  type        = string
  default     = "coder.demo/org"
  description = "If set, the namespace must also carry this label with the organisation as its value. Empty to check existence only."
}

variable "node_label_pattern" {
  type        = string
  default     = "coder.demo/org-<org>"
  description = "Node label key (value \"true\") for the organisation's nodes; <org> is replaced. Empty for no node selector."
}

variable "org_label_key" {
  type        = string
  default     = "coder.demo/org"
  description = "Key of the organisation label in the `labels` output. Empty to omit."
}

# -------------------------------------------------------------- enforcement

variable "require_organisation" {
  type        = bool
  default     = true
  description = "Fail starts when the workspace has no supported organisation."
}

variable "recheck_on_start" {
  type        = bool
  default     = true
  description = "Fail starts when the user is no longer in the pinned organisation."
}

variable "support_contact" {
  type        = string
  default     = "your Coder administrator"
  description = "Who users should contact, shown in every error message."
}
