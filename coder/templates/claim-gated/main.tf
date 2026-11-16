terraform {
  required_providers {
    coder      = { source = "coder/coder", version = "~> 2.20" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    http       = { source = "hashicorp/http", version = "~> 3.5" }
  }
}

variable "claim_source" {
  type        = string
  default     = "userinfo"
  description = "Where to read the organisations claim: \"userinfo\" or \"access_token\". See modules/oidc-claims."
}

variable "oidc_userinfo_url" {
  type        = string
  default     = "http://keycloak.192.168.88.253.nip.io/realms/coder/protocol/openid-connect/userinfo"
  description = "The IdP's userinfo_endpoint (from /.well-known/openid-configuration)."
}

# Admin-only (set with `coder templates push --variables-file`); users never
# see it. Allow-list of organisations that have a <org>-workspaces namespace,
# in priority order: a user in several gets the first one listed. Claim values
# not in this list are ignored.
variable "organisations" {
  type        = list(string)
  default     = ["acme", "globex"]
  description = "Organisations with a tenant, highest priority first."
  sensitive   = true # Coder redacts the value in its API for everyone
}

variable "groups_claim" {
  type        = string
  default     = "groups"
  description = "Name of the claim holding the user's IdP groups (\"groups\" for Keycloak, Okta and Entra ID)."
}

variable "group_pattern" {
  type        = string
  default     = "^/?(.+)$"
  description = "Regex extracting the group name from each groups claim value (first capture group). Keycloak: the default; LDAP DNs (Ping): \"^(?i)cn=([^,]+)\"."
}

# JSON, since template variables can't be maps.
variable "group_names" {
  type        = string
  default     = "{}"
  description = "JSON object renaming group values, e.g. Entra ID object IDs: {\"6f1c...\": \"USER_DEVELOPER\"}."
}

# In-cluster config: the provisioner runs inside the Coder pod as SA coder/coder.
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

module "claims" {
  source       = "./modules/oidc-claims"
  claim_source = var.claim_source
  userinfo_url = var.oidc_userinfo_url
  # Only on start: stop/delete must work even if the user lost their org or SSO session.
  fetch         = data.coder_workspace.me.start_count == 1
  groups_claim  = var.groups_claim
  group_pattern = var.group_pattern
  group_names   = jsondecode(var.group_names)
}

# ---------------------------------------------------------------------------
# Workspace profile, gated by IdP group. Options are fixed here; a profile with
# a required_group starts only for users whose groups claim contains it.
# Mutable, so a user who loses the group can switch back to Standard.
# ---------------------------------------------------------------------------
locals {
  profiles = {
    standard  = { name = "Standard", required_group = null, cpu = "2", memory = "2Gi" }
    developer = { name = "Developer", required_group = "USER_DEVELOPER", cpu = "4", memory = "8Gi" }
  }
  profile = local.profiles[module.profile.value]
}

module "profile" {
  source       = "./modules/gated-parameter"
  name         = "profile"
  display_name = "Workspace profile"
  description  = "Developer requires membership of the USER_DEVELOPER group in SSO."
  default      = "standard"
  user_groups  = module.claims.groups
  # Entra ID group overage: say so in the error rather than just "not in group".
  groups_incomplete = module.claims.groups_overage
  options = { for k, p in local.profiles : k => {
    name           = p.name
    description    = "${p.cpu} CPU, ${p.memory}."
    required_group = p.required_group
  } }
}

locals {
  orgs       = module.claims.organisations
  is_import  = module.claims.is_import
  eligible   = nonsensitive([for o in var.organisations : o if contains(local.orgs, o)])
  resolved   = length(local.eligible) > 0 ? local.eligible[0] : "none"
  org        = terraform_data.org.output
  namespace  = "${local.org}-workspaces"
  node_label = "coder.demo/org-${local.org}"
  name       = "coder-${data.coder_workspace.me.id}"
  labels = {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = local.name
    "coder.demo/org"             = local.org
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  }
}

# Pin the organisation on the first build. Without this, it would be
# re-resolved on every build and a claim change would move the workspace's
# volume to another namespace.
resource "terraform_data" "org" {
  input = local.resolved
  lifecycle { ignore_changes = [input] }
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch
  dir  = "/home/coder"

  metadata {
    display_name = "Organisation"
    key          = "org"
    script       = "echo ${local.org} / $POD_NAMESPACE on $NODE_NAME"
    interval     = 0
  }

  metadata {
    display_name = "Profile"
    key          = "profile"
    script       = "echo ${local.profile.name}"
    interval     = 0
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  metadata {
    name      = "${local.name}-home"
    namespace = local.namespace
    labels    = local.labels
  }
  wait_until_bound = false

  # Org is pinned, so this only fails when the user had no eligible org at
  # creation; it never blocks stopping or deleting a real workspace.
  lifecycle {
    precondition {
      condition     = local.is_import || local.org != "none"
      error_message = "Your identity has no 'organisations' claim matching an enabled organisation (claims: ${jsonencode(local.orgs)}). Ask an admin to add you to an organisation."
    }
  }
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false
  depends_on       = [kubernetes_persistent_volume_claim_v1.home]

  # Checked only when starting (this resource only exists while started), so a
  # user who lost the org can't start the workspace but it can still be stopped
  # and deleted.
  lifecycle {
    precondition {
      condition     = local.is_import || contains(local.orgs, local.org)
      error_message = "Your identity has no 'organisations' claim matching '${local.org}' (claims: ${jsonencode(local.orgs)}). Sign in with SSO, or ask an admin to add you to an organisation."
    }
    # The uid term is unknown on a new workspace, which defers this check to
    # apply, after the org pin and PVC exist. Failing at plan would leave no
    # pin, and the next stop/delete would fail resolving the org.
    precondition {
      condition     = local.is_import || module.profile.allowed || kubernetes_persistent_volume_claim_v1.home.metadata[0].uid == ""
      error_message = module.profile.error_message
    }
  }

  metadata {
    name      = local.name
    namespace = local.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { "app.kubernetes.io/instance" = local.name } }

    template {
      metadata { labels = local.labels }
      spec {
        # Requested here for clarity; enforced cluster-side regardless.
        node_selector                   = { (local.node_label) = "true" }
        automount_service_account_token = false
        enable_service_links            = false

        security_context {
          run_as_user     = 1000
          run_as_group    = 1000
          run_as_non_root = true
          fs_group        = 1000
          seccomp_profile { type = "RuntimeDefault" }
        }

        container {
          name              = "dev"
          image             = "codercom/enterprise-base:ubuntu"
          image_pull_policy = "IfNotPresent"
          command           = ["sh", "-c", coder_agent.main.init_script]
          env {
            name = "POD_NAMESPACE"
            value_from {
              field_ref { field_path = "metadata.namespace" }
            }
          }
          env {
            name = "NODE_NAME"
            value_from {
              field_ref { field_path = "spec.nodeName" }
            }
          }
          env {
            name  = "CODER_AGENT_TOKEN"
            value = coder_agent.main.token
          }
          resources {
            requests = { cpu = "250m", memory = "512Mi" }
            limits   = { cpu = local.profile.cpu, memory = local.profile.memory }
          }
          security_context {
            run_as_non_root            = true # provider otherwise sends false explicitly
            allow_privilege_escalation = false
            capabilities { drop = ["ALL"] }
          }
          volume_mount {
            name       = "home"
            mount_path = "/home/coder"
          }
        }

        volume {
          name = "home"
          persistent_volume_claim { claim_name = kubernetes_persistent_volume_claim_v1.home.metadata[0].name }
        }
      }
    }
  }
}
