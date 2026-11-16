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
  default     = ""
  description = "The IdP's userinfo_endpoint (from /.well-known/openid-configuration). Required for claim_source = \"userinfo\"."
  validation {
    condition     = var.claim_source != "userinfo" || var.userinfo_url != ""
    error_message = "userinfo_url is required when claim_source is \"userinfo\"."
  }
}

variable "fetch" {
  type        = bool
  default     = null
  description = "Call userinfo on this build. Default: only when the workspace is starting, so stop and delete work without an SSO session."
}
