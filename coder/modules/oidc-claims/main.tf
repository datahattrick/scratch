# Reads the workspace owner's OIDC claims in Coder OSS.
#
# Coder OSS doesn't expose arbitrary OIDC claims (or the ID token) to
# templates, and IdP group/org sync is Premium. It does pass the owner's OIDC
# access token, which gets us the claims one of two ways:
#
#   userinfo     - call the IdP's userinfo endpoint with the access token. Works
#                  when the claim is only in the ID token / userinfo, works with
#                  opaque access tokens, and the IdP validates the token.
#   access_token - decode the JWT access token locally. No network call, but
#                  needs the claim in the access token; signature not verified.
#
# Only real workspace builds get a token (not import, dry-run or the dashboard
# parameter preview), so the lookup is skipped when the token is empty.
#
# Files: main.tf (providers, data sources), variables.tf, locals.tf,
# outputs.tf.

terraform {
  required_providers {
    coder = { source = "coder/coder" }
    http  = { source = "hashicorp/http" }
  }
}

data "coder_workspace_owner" "me" {}

data "http" "userinfo" {
  count = var.claim_source == "userinfo" && local.has_token && var.fetch ? 1 : 0
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
