variable "claim_source" {
  type        = string
  default     = "userinfo"
  description = "\"userinfo\" (IdP userinfo endpoint) or \"access_token\" (decode the JWT access token)."
  validation {
    condition     = contains(["userinfo", "access_token"], var.claim_source)
    error_message = "claim_source must be \"userinfo\" or \"access_token\"."
  }
}

variable "userinfo_url" {
  type        = string
  description = "The IdP's userinfo_endpoint (from /.well-known/openid-configuration)."
}

variable "fetch" {
  type        = bool
  description = "Call userinfo on this build. Pass start_count == 1 so stop/delete work without an SSO session."
}

variable "organisations_claim" {
  type        = string
  default     = "organisations"
  description = "Name of the claim holding the user's organisations."
}

variable "organisation_name_regex" {
  type        = string
  default     = "^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$"
  description = "Organisation values (after lower-casing, if enabled) not matching this are dropped. The default keeps names usable in a namespace name."
}

variable "lowercase_organisations" {
  type        = bool
  default     = true
  description = "Lower-case organisation values before filtering."
}

variable "groups_claim" {
  type        = string
  default     = "groups"
  description = "Name of the claim holding the user's IdP groups (Keycloak, Entra ID: \"groups\"; PingFederate often \"memberOf\")."
}

variable "group_pattern" {
  type        = string
  default     = "^/?(.+)$"
  description = "RE2 regex applied to each group value. Values not matching are dropped; the first capture group (or the whole match, if none) is the group name. The default strips Keycloak's leading \"/\". For LDAP DNs: \"^(?i)cn=([^,]+)\"."
}

variable "group_names" {
  type        = map(string)
  default     = {}
  description = "Renames group values after group_pattern, e.g. Entra ID object IDs to names: { \"6f1c...\" = \"USER_DEVELOPER\" }. Unmapped values are kept."
}
