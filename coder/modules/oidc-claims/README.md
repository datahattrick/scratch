# oidc-claims

The workspace owner's OIDC claims, for any Coder template.
Works on Coder OSS.

The module has no knowledge of organisations, groups or placement.
It returns what the IdP sent; the template decides what a claim means.

## Usage

```hcl
module "oidc" {
  source       = "./modules/oidc-claims"
  userinfo_url = "https://idp.example/realms/x/protocol/openid-connect/userinfo"
}

locals {
  email  = try(module.oidc.claims.email, "")
  groups = lookup(module.oidc.lists, "groups", [])
  team   = try(module.oidc.claims.team, "none")
}

resource "kubernetes_deployment_v1" "main" {
  count = data.coder_workspace.me.start_count

  lifecycle {
    precondition {
      condition     = module.oidc.is_import || contains(local.groups, "developers")
      error_message = "This template needs the 'developers' group."
    }
  }
}
```

The template needs `coder/coder` and `hashicorp/http` in `required_providers`, a `modules` symlink to `../../modules`, and is pushed with `scripts/push-template.sh`.

## Variables

| Name | Default | Purpose |
|---|---|---|
| `claim_source` | `userinfo` | `userinfo` calls the IdP; `access_token` decodes the JWT access token |
| `userinfo_url` | `""` | IdP userinfo endpoint; required for `userinfo` |
| `fetch` | start only | Call userinfo on this build |

## Outputs

| Name | Value |
|---|---|
| `claims` | Every claim, typed as the IdP sent it |
| `lists` | Claim name to `list(string)`, for scalar claims and lists of scalars |
| `incomplete` | Names of claims the IdP left out (Entra ID group overage) |
| `has_token` | False for password-login users, import, dry-run and the parameter preview |
| `is_import` | True during template import and dry-run |

## Behaviour

- With `userinfo`, `claims` is `{}` on stop and delete. Put claim checks on resources that exist only while started.
- With `access_token`, the claims are those of the last Coder login, and the JWT signature is not verified. [Detail](../../docs/design.md#reading-the-claim)
- A non-200 userinfo response fails the build with `userinfo request failed with HTTP 401. Sign out of Coder and back in to refresh your SSO session.`
- The dashboard parameter preview has no token, so claims cannot filter parameter options.
- Claims are not marked sensitive and appear in build logs.
