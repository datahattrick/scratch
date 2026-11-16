# org-mapping

Maps a Coder workspace owner to an organisation and namespace, pins it, and enforces it.
Works on Coder OSS.

- Takes the owner's organisations as a list, usually an OIDC claim read with [`oidc-claims`](../oidc-claims/README.md).
- Turns each organisation into a namespace with `namespace_pattern` (`test-<org>`); the organisation is supported if that namespace exists and carries `namespace_org_label=<org>`.
- Uses the first supported organisation alphabetically.
- Pins the organisation and namespace on the first build; claim or pattern changes never move a workspace.
- Fails a start when the user has no supported organisation, or has left the pinned one. Stop and delete never check.
- A workspace created without an organisation never starts, and deletes cleanly.

Files: [`main.tf`](main.tf) (providers, data sources, resources), [`variables.tf`](variables.tf), [`locals.tf`](locals.tf), [`outputs.tf`](outputs.tf).

Needs `get` on namespaces for the provisioner: [`tenancy/namespace-lookup.yaml`](../../tenancy/namespace-lookup.yaml).

## Usage

```hcl
module "oidc" {
  source       = "./modules/oidc-claims"
  userinfo_url = "https://idp.example/realms/x/protocol/openid-connect/userinfo"
}

module "org" {
  source            = "./modules/org-mapping"
  organisations     = lookup(module.oidc.lists, "organisations", [])
  namespace_pattern = "test-<org>"
  support_contact   = "the platform team"
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  count = module.org.has_org ? 1 : 0
  metadata {
    namespace = module.org.namespace
    labels    = module.org.labels
    # ...
  }
}

resource "kubernetes_deployment_v1" "main" {
  count      = data.coder_workspace.me.start_count
  depends_on = [module.org]
  # namespace = module.org.namespace, node_selector = module.org.node_selector
}
```

Gate anything that must not exist without an organisation on `has_org`, which is known at plan.
The template needs a `modules` symlink to `../../modules` and is pushed with `scripts/push-template.sh`.
[`templates/egress-zoned`](../../templates/egress-zoned/main.tf) is a complete example.

Moving a template's own pin into the module:

```hcl
moved {
  from = terraform_data.org
  to   = module.org.terraform_data.org
}
```

## Variables

| Name | Default | Purpose |
|---|---|---|
| `organisations` | required | The owner's organisations |
| `namespace_pattern` | `<org>-workspaces` | Namespace per organisation; must contain `<org>` |
| `namespace_org_label` | `coder.demo/org` | Label the namespace must carry with the organisation as value; empty for existence only |
| `support_contact` | `your Coder administrator` | Shown in every error |
| `organisation_name_regex` | DNS label, ≤42 chars | Values not matching are ignored |
| `lowercase_organisations` | `true` | Lower-case values before matching |
| `node_label_pattern` | `coder.demo/org-<org>` | Node label key; empty for no node selector |
| `org_label_key` | `coder.demo/org` | Key of the organisation label in `labels`; empty for none |
| `require_organisation` | `true` | Fail starts with no supported organisation |
| `recheck_on_start` | `true` | Fail starts after the user leaves the pinned organisation |

## Outputs

| Name | Value |
|---|---|
| `organisation` | Pinned organisation, or `none` |
| `has_org` | `organisation != "none"`, known at plan |
| `namespace` | Pinned namespace |
| `node_selector` | `{ <node label> = "true" }`, or `{}` |
| `labels` | `{ <org_label_key> = <organisation> }`, or `{}` |
| `user_organisations` | `organisations` after normalising and filtering, supported or not |

## Errors

```
Sorry, the 'globex' organisation is not supported at this time. If you believe this is an error, please contact <support_contact>.
Sorry, your organisations (acme, globex) are not supported at this time. ...
Sorry, your account is not in any organisation. ...
You are no longer in the 'globex' organisation (your organisations: []). ...
This workspace was created before your organisation was supported. Delete it and create a new one.
```
