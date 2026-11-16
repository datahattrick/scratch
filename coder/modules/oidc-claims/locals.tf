locals {
  # Template import and CLI dry-runs have no real owner (login_type unset);
  # every real workspace build has login_type set.
  is_import = try(data.coder_workspace_owner.me.login_type, null) == null

  access_token = data.coder_workspace_owner.me.oidc_access_token
  has_token    = nonsensitive(length(local.access_token) > 0)

  token_parts = split(".", local.access_token)
  payload_b64 = length(local.token_parts) == 3 ? replace(replace(local.token_parts[1], "-", "+"), "_", "/") : ""
  payload_pad = join("", [for i in range((4 - length(local.payload_b64) % 4) % 4) : "="])
  jwt_json    = try(base64decode("${local.payload_b64}${local.payload_pad}"), "{}")

  claims_json = var.claim_source == "userinfo" ? try(data.http.userinfo[0].response_body, "{}") : local.jwt_json
  claims      = try(jsondecode(local.claims_json), {})

  # Accept a list or a single string; keep only names matching the regex.
  raw_orgs  = try(tolist(local.claims[var.organisations_claim]), try([tostring(local.claims[var.organisations_claim])], []))
  norm_orgs = [for o in local.raw_orgs : var.lowercase_organisations ? lower(o) : o]
  orgs      = nonsensitive(sort(distinct([for o in local.norm_orgs : o if can(regex(var.organisation_name_regex, o))])))

  # Compared exactly (case-sensitive) by callers. group_pattern extracts the
  # name (regex returns a list when the pattern has capture groups, a string
  # otherwise); group_names then renames, e.g. Entra object IDs.
  raw_groups     = try(tolist(local.claims[var.groups_claim]), try([tostring(local.claims[var.groups_claim])], []))
  matched_groups = [for g in local.raw_groups : try(regex(var.group_pattern, g)[0], regex(var.group_pattern, g)) if can(regex(var.group_pattern, g))]
  groups         = nonsensitive(sort(distinct([for g in local.matched_groups : lookup(var.group_names, g, g)])))

  # Entra ID leaves out the groups claim when the user is in too many groups
  # (over 200 in a JWT) and points to Microsoft Graph instead.
  groups_overage = nonsensitive(can(local.claims["_claim_names"][var.groups_claim]))
}
