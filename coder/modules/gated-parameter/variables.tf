variable "name" {
  type = string
}

variable "display_name" {
  type = string
}

variable "description" {
  type    = string
  default = ""
}

variable "default" {
  type = string
}

variable "mutable" {
  type    = bool
  default = true
}

variable "options" {
  type = map(object({
    name           = string
    description    = optional(string, "")
    required_group = optional(string)
  }))
  description = "Option value => display name, description and the group it requires (null for none)."
}

variable "user_groups" {
  type        = list(string)
  description = "The user's groups, e.g. module.claims.groups."
}

variable "groups_incomplete" {
  type        = bool
  default     = false
  description = "The IdP left groups out (module.claims.groups_overage); the error message says so."
}
