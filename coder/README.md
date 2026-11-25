# Coder per-organisation isolation (OSS)

Coder OSS workspaces placed into a namespace and onto nodes chosen by the user's `organisations` OIDC claim.
Users see no organisation field; the template resolves it from their SSO account.

## Layout

| Path | Contents |
|---|---|
| `modules/oidc-claims` | The owner's OIDC claims, for any template. [Usage](modules/oidc-claims/README.md) |
| `modules/org-mapping` | Maps a list of organisations to an existing `<pattern>` namespace, pins and enforces it. [Usage](modules/org-mapping/README.md) |
| `modules/gated-parameter` | A parameter whose options can each require a group |
| `templates/org-isolated` | Claim-based org placement. Uses `oidc-claims` |
| `templates/claim-gated` | `org-isolated` plus a group-gated workspace profile. Uses `oidc-claims` and `gated-parameter` |
| `templates/egress-zoned` | `org-isolated` in `<org>-zoned-workspaces`, egress only through the org's zone proxy. Uses `oidc-claims` and `org-mapping` |
| `templates/org-netpol` | Example: a NetworkPolicy per workspace built from the `organisations` claim. Uses `oidc-claims` and `org-mapping` |
| `tenancy/template-network-policies.yaml` | Lets the provisioner manage NetworkPolicies in the org namespaces, for `org-netpol` |
| `tenancy/egress-zones.yaml` | One stand-in proxy (Squid) per network zone |
| `tenancy/zoned-orgs.yaml` | `<org>-zoned-workspaces` namespaces, each assigned a zone |
| `derp` | Helm chart for a standalone, multi-node DERP relay and STUN server, for networks without internet access. [Usage](derp/README.md) |

Each template is pushed under its own name, so they can be changed and tested independently.
Templates reach the modules through a `modules` symlink.
Every template reads claims through `oidc-claims`, which returns them as sent and has no organisation or group logic.
The other two modules are optional and take plain lists, so a template can feed them any claim.
`org-isolated` and `claim-gated` predate `org-mapping` and still inline the placement.

- **Generic claims module**: `module.oidc.claims` holds every claim, `module.oidc.lists` each one as a list of strings. [Detail](modules/oidc-claims/README.md)
- **Claim-based placement**: the template reads `organisations` from the IdP's userinfo endpoint (or the JWT access token) and deploys into `<org>-workspaces`. [Detail](docs/design.md#reading-the-claim)
- **Admin-controlled organisations**: `org-isolated` and `claim-gated` list enabled organisations in a sensitive template variable. `egress-zoned` supports any organisation whose namespace exists. [Detail](docs/design.md#choosing-the-organisation)
- **Start-time authorisation**: starting a workspace for an organisation no longer in the user's claim fails. Stop and delete always work.
- **Group-gated profiles** (`claim-gated` only): the `Developer` workspace profile starts only for users whose `groups` claim contains `USER_DEVELOPER`. [Detail](docs/design.md#group-gated-profiles)
- **Pinned organisation**: resolved on the first build and kept in state, so a claim or priority change never moves a workspace.
- **Node pinning**: workspace pods select `coder.demo/org-<org>=true`. [Detail](docs/design.md#node-isolation)
- **Network isolation**: pods accept traffic only from namespaces of the same organisation.
- **Egress zones** (`egress-zoned` only): each org's workspaces reach the network only through their zone's proxy. [Detail](docs/design.md#egress-zones)
- **Claim-based network policy** (`org-netpol` only): each workspace accepts traffic from the namespaces of every organisation in its owner's claim. [Detail](#network-policy-per-workspace-org-netpol)
- **Scoped provisioner**: Coder's service account can only write to `*-workspaces` namespaces.

## Requirements

1. An IdP that returns `organisations` from its **userinfo endpoint** (set `oidc_userinfo_url`), or puts it in a **JWT access token** (set `claim_source = "access_token"`). The test realm maps Keycloak groups to it in the ID token and userinfo only.
2. The `offline_access` scope granted to users, so Coder can refresh the token at build time.
3. Kubernetes 1.30+ for the admission policies, and a CNI that enforces NetworkPolicy.
4. Nodes labelled `coder.demo/org-<org>=true` (and ideally tainted per org).

## Deploy

```bash
./scripts/deploy.sh                                   # Postgres, Keycloak (test IdP), Coder 2.39.1
kubectl apply -f tenancy/orgs.yaml                    # Namespace, RBAC, NetworkPolicy, quota per org
kubectl label node <node> coder.demo/org-acme=true
kubectl apply -f tenancy/node-isolation-policy.yaml   # Enforce node pinning
scripts/push-template.sh org-isolated
scripts/push-template.sh claim-gated
kubectl apply -f tenancy/egress-zones.yaml -f tenancy/zoned-orgs.yaml   # Zone proxies, zoned namespaces
kubectl apply -f tenancy/namespace-lookup.yaml       # Provisioner may get namespaces (org-mapping)
scripts/push-template.sh egress-zoned
kubectl apply -f tenancy/template-network-policies.yaml   # Provisioner may manage NetworkPolicies (org-netpol)
scripts/push-template.sh org-netpol
```

`push-template.sh` copies the template with its `modules` symlink resolved, since Coder uploads symlinks as-is.
It passes `templates/<name>/variables.yaml` when present.
Set `CODER` to use a `coder` binary not on `PATH`, and `TEMPLATE_NAME` to push under another name.

To try a namespace pattern without touching the live template, push a copy:

```bash
TEMPLATE_NAME=egress-zoned-test scripts/push-template.sh egress-zoned --variable 'namespace_pattern=test-<org>'
```

Adding an organisation means copying an org block in `tenancy/orgs.yaml` (or `tenancy/zoned-orgs.yaml`) and labelling its nodes.
`org-isolated` and `claim-gated` also need it added to their `organisations` variable.

Generated passwords are in the `coder/demo-users` Secret.
Test users: `alice` (acme, developer), `bob` (globex), `carol` (both, developer), `dave` (none).

## Organisations variable (`org-isolated`, `claim-gated`)

```yaml
organisations: '["globex", "acme"]'    # Enabled orgs, highest priority first
```

A user in several organisations gets the first one listed.
Claim values not in the list are ignored.
The value is redacted in Coder's API for every user, admins included.
Pass it with `--variables-file`; `--variable` cannot parse a JSON list.

A user with no enabled organisation gets:

```
Your identity has no 'organisations' claim matching an enabled organisation (claims: []).
```

Claim changes take effect at the next start with `userinfo`, or the next Coder login with `access_token`.
A user removed from an organisation can stop and delete that organisation's workspaces but not start them.

## Workspace profiles (`claim-gated`)

| Profile | Limits | Required group |
|---|---|---|
| Standard | 2 CPU, 2Gi | none |
| Developer | 4 CPU, 8Gi | `USER_DEVELOPER` |

Profiles and their groups are set in `local.profiles` in `templates/claim-gated/main.tf`.
The group claim name is `var.groups_claim` (default `groups`).
`var.group_pattern` and `var.group_names` (JSON) adapt group values for Entra ID and Ping. [Detail](docs/design.md#group-gated-profiles)
Group names are case-sensitive.

Starting a Developer workspace without the group fails with:

```
The Developer option of 'Workspace profile' requires the 'USER_DEVELOPER' group (your groups: ["globex"]).
```

The profile is mutable, so a user who loses the group can switch to Standard and keep their volume.
`coder start` and `coder restart` reuse the stored value; change it with `coder update --parameter`, the dashboard, or the builds API.

## Egress zones (`egress-zoned`)

| Org | Zone | Proxy allows |
|---|---|---|
| acme | `restricted` | `github.com`, `githubusercontent.com` |
| globex | `open` | any host, ports 80/443 |

The zone is the `coder.demo/egress-zone` label on `<org>-zoned-workspaces`, set in `tenancy/zoned-orgs.yaml`.
The template does not know the zone; pods get `HTTP(S)_PROXY` from the namespace's `egress-proxy` ConfigMap.
Moving an org to another zone means changing its label and ConfigMap; restart workspaces to pick up the new proxy.

Measured from acme and globex workspaces:

| From | `github.com` via proxy | `example.com` via proxy | Direct internet | Other zone's proxy | Other cluster services |
|---|:---:|:---:|:---:|:---:|:---:|
| acme (`restricted`) | ✅ | ❌ 403 | ❌ | ❌ | ❌ |
| globex (`open`) | ✅ | ✅ | ❌ | ❌ | ❌ |

### Supported organisations

An organisation is supported when the namespace `namespace_pattern` gives for it exists and carries `coder.demo/org=<org>`.
There is no list in the template; creating or deleting the namespace enables or disables the organisation.

| Variable | Default | Purpose |
|---|---|---|
| `namespace_pattern` | `<org>-zoned-workspaces` | Namespace per organisation, e.g. `test-<org>` |
| `support_contact` | `your Coder administrator` | Shown in every error |

`claim_source`, `oidc_userinfo_url` and `organisations_claim` select the claim.
Every other `modules/org-mapping` variable is also a template variable. [Detail](modules/org-mapping/README.md#variables)

A user in several supported organisations gets the first alphabetically.
Users get an error on creation, and the workspace can be deleted:

```
Sorry, the 'globex' organisation is not supported at this time. If you believe this is an error, please contact the platform team (#coder-help).
Sorry, your account is not in any organisation. If you believe this is an error, please contact the platform team (#coder-help).
```

The namespace is pinned on the first build; changing `namespace_pattern` affects new workspaces only.

Each pod has a 1-hour service account token for audience `egress-proxy` at `$EGRESS_PROXY_TOKEN_FILE`, for the future auth proxy.

## Network policy per workspace (`org-netpol`)

An example of building Kubernetes objects from a claim.
The workspace runs in `<org>-workspaces` and gets one NetworkPolicy selecting its pod:

```hcl
peer_orgs = distinct(concat([module.org.organisation], module.org.user_organisations))

ingress {
  dynamic "from" {
    for_each = local.peer_orgs
    content {
      namespace_selector { match_labels = { "coder.demo/org" = from.value } }
    }
  }
}
```

| Owner's claim | Workspace namespace | Accepts traffic from namespaces labelled |
|---|---|---|
| `acme` | `acme-workspaces` | `coder.demo/org=acme` |
| `acme`, `globex` | `acme-workspaces` | `coder.demo/org=acme`, `coder.demo/org=globex` |

The policy exists while the workspace is started and is rebuilt from the claim on each start.
NetworkPolicies add up, so it widens what the namespace's `org-isolation` policy allows and does not narrow it.
It needs `tenancy/template-network-policies.yaml`, which lets any template open an org namespace to other traffic.

Not yet run on the cluster: `terraform validate` and a server-side dry run of the RBAC only.

## Known issues

- **Multi-org users cannot choose.** They get the highest-priority (`egress-zoned`: alphabetically first) supported organisation. [Detail](docs/design.md#choosing-the-organisation)
- **Node pinning needs the admission policies.** Until `tenancy/node-isolation-policy.yaml` is applied, it is only what the template requests. [Detail](docs/design.md#node-isolation)
- **Every user sees every profile.** The dashboard has no token when it renders parameters, so options cannot be filtered per user. [Detail](docs/design.md#group-gated-profiles)
- **Quota failures report as a successful build.** The template does not wait for rollout, so a pod refused by the namespace `ResourceQuota` leaves a started but unhealthy workspace. Two Developer workspaces plus two Standard ones fill the 8-CPU org quota.
- **A workspace with no enabled organisation gets stuck** (`org-isolated` and `claim-gated`; fixed in `org-mapping`). Its first build fails at plan, so the next stop or delete fails too. Remove it with `coder delete --orphan`. [Detail](docs/design.md#lifecycle)
- **DNS is open** (`egress-zoned`). Pods can query cluster DNS, which resolves external names, so DNS tunnelling is possible. [Detail](docs/design.md#egress-zones)
- **The Coder Service IP is a template variable** (`egress-zoned`). If the `coder` Service is recreated, set `coder_service_ip` to the new ClusterIP or agents cannot connect.
- **Password-login users cannot start workspaces.** They have no OIDC token.

## Future

- Taint org nodes and add matching tolerations
- Production Keycloak (persistent DB, TLS)
- One external provisioner per organisation, each with its own service account
- Auth proxy in place of Squid, authenticating workspaces by their `egress-proxy` token
- Move `org-isolated` and `claim-gated` onto `org-mapping`

## Documentation

| Doc | Contents |
|---|---|
| [docs/design.md](docs/design.md) | OSS vs Premium options, claim sources, organisation choice, group-gated profiles, egress zones, lifecycle, node isolation |
