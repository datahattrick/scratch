locals {
  # Template import and CLI dry-runs have no real owner (login_type unset);
  # every real workspace build has login_type set.
  is_import = try(data.coder_workspace_owner.me.login_type, null) == null

  access_token = data.coder_workspace_owner.me.oidc_access_token
  has_token    = nonsensitive(length(local.access_token) > 0)
  fetch        = coalesce(var.fetch, data.coder_workspace.me.start_count == 1)

  # JWT payload: base64url to padded base64.
  token_parts = split(".", local.access_token)
  payload_b64 = length(local.token_parts) == 3 ? replace(replace(local.token_parts[1], "-", "+"), "_", "/") : ""
  payload_pad = join("", [for i in range((4 - length(local.payload_b64) % 4) % 4) : "="])
  jwt_json    = try(base64decode("${local.payload_b64}${local.payload_pad}"), "{}")

  # Claims are identity data, not a credential, so they are exposed
  # non-sensitive and can be used in count, for_each and resource names.
  # sensitive() first: nonsensitive() rejects an unmarked value on older
  # Terraform, and only the JWT path is marked.
  claims_json = var.claim_source == "userinfo" ? try(data.http.userinfo[0].response_body, "{}") : local.jwt_json
  claims      = nonsensitive(sensitive(try(jsondecode(local.claims_json), {})))

  # Every claim that is a scalar or a list of scalars, as list(string).
  lists = try({
    for k, v in local.claims : k => try([for x in tolist(v) : tostring(x)], [tostring(v)])
    if can([for x in tolist(v) : tostring(x)]) || can(tostring(v))
  }, {})

  # Claims the IdP left out and points to elsewhere (OIDC distributed claims),
  # e.g. Entra ID's groups when the user is in more than 200.
  incomplete = try(keys(local.claims["_claim_names"]), [])
}
