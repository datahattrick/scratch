# ------------------------------------------------------------ organisations

variable "organisations" {
  type        = list(string)
  description = "The owner's organisations, e.g. lookup(module.oidc.lists, \"organisations\", []). May be empty on stop and delete."
}

variable "organisation_name_regex" {
  type        = string
  default     = "^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$"
  description = "Values not matching this are ignored. The default keeps names usable in a namespace name."
}

variable "lowercase_organisations" {
  type        = bool
  default     = true
  description = "Lower-case values before matching."
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
