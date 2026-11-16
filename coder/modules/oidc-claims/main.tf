# The workspace owner's OIDC claims, for any template (Coder OSS).
#
#   module "oidc" {
#     source       = "./modules/oidc-claims"
#     userinfo_url = "https://idp.example/userinfo"
#   }
#
#   module.oidc.claims.email                      # any claim, as the IdP sent it
#   lookup(module.oidc.lists, "groups", [])       # a claim as list(string)
#
# The module knows nothing about organisations, groups or placement; what a
# claim means is up to the template.
#
# Coder passes templates the owner's OIDC access token, not the claims. They
# are read one of two ways:
#
#   userinfo     - call the IdP's userinfo endpoint with the access token.
#   access_token - decode the JWT access token. No network call; the signature
#                  is not verified.
#
# Only workspace builds get a token (not import, dry-run or the dashboard
# parameter preview); without one, claims is {}.
#
# Files: main.tf (providers, data sources), variables.tf, locals.tf,
# outputs.tf.

terraform {
  required_providers {
    coder = { source = "coder/coder" }
    http  = { source = "hashicorp/http" }
  }
}

data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

data "http" "userinfo" {
  count = var.claim_source == "userinfo" && local.has_token && local.fetch ? 1 : 0
  url   = var.userinfo_url
  request_headers = {
    Authorization = "Bearer ${local.access_token}"
    Accept        = "application/json"
  }
  retry { attempts = 2 }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "userinfo request failed with HTTP ${self.status_code}. Sign out of Coder and back in to refresh your SSO session."
    }
  }
}
