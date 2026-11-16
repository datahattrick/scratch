# Example: a NetworkPolicy per workspace, built from the owner's OIDC claims.
#
# The workspace runs in the namespace of one of the owner's organisations
# (modules/org-mapping) and accepts traffic from the namespaces of every
# organisation in the owner's claim. A user in acme and globex gets a
# workspace reachable from both; a user in acme only, from acme only.
#
# Needs networkpolicies rights for the provisioner:
# tenancy/template-network-policies.yaml.

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
  description = "Where to read the claims: \"userinfo\" or \"access_token\". See modules/oidc-claims."
}

variable "oidc_userinfo_url" {
  type        = string
  default     = "http://keycloak.192.168.88.253.nip.io/realms/coder/protocol/openid-connect/userinfo"
  description = "The IdP's userinfo_endpoint (from /.well-known/openid-configuration)."
}

variable "organisations_claim" {
  type        = string
  default     = "organisations"
  description = "Name of the claim holding the user's organisations."
}

variable "namespace_pattern" {
  type        = string
  default     = "<org>-workspaces"
  description = "Namespace for an organisation; <org> is replaced."
}

variable "namespace_org_label" {
  type        = string
  default     = "coder.demo/org"
  description = "Namespace label holding the organisation. Used to place the workspace and as the NetworkPolicy's namespace selector."
}

# In-cluster config: the provisioner runs inside the Coder pod as SA coder/coder.
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

module "oidc" {
  source       = "./modules/oidc-claims"
  claim_source = var.claim_source
  userinfo_url = var.oidc_userinfo_url
}

module "org" {
  source              = "./modules/org-mapping"
  organisations       = lookup(module.oidc.lists, var.organisations_claim, [])
  namespace_pattern   = var.namespace_pattern
  namespace_org_label = var.namespace_org_label
}

locals {
  name = "coder-${data.coder_workspace.me.id}"
  labels = merge(module.org.labels, {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = local.name
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  })

  # Organisations whose namespaces may reach this workspace: the workspace's
  # own, plus every other one in the owner's claim. Never empty, since an
  # ingress rule with no `from` allows everything.
  peer_orgs = distinct(concat([module.org.organisation], module.org.user_organisations))
}

resource "coder_agent" "main" {
  os   = "linux"
  arch = data.coder_provisioner.me.arch
  dir  = "/home/coder"

  metadata {
    display_name = "Organisation"
    key          = "org"
    script       = "echo ${module.org.organisation} / $POD_NAMESPACE on $NODE_NAME"
    interval     = 0
  }

  metadata {
    display_name = "Reachable from"
    key          = "peers"
    script       = "echo ${join(", ", local.peer_orgs)}"
    interval     = 0
  }
}

# One policy per workspace, selecting only its pod. It exists while the
# workspace is started and is rebuilt from the claim on every start, so a
# change of organisations applies at the next start.
#
# NetworkPolicies add up: this allows traffic in addition to whatever the
# namespace's own policies allow, and cannot take any of that away.
resource "kubernetes_network_policy_v1" "workspace" {
  count      = module.org.has_org ? data.coder_workspace.me.start_count : 0
  depends_on = [module.org]

  metadata {
    name      = local.name
    namespace = module.org.namespace
    labels    = local.labels
  }

  spec {
    pod_selector { match_labels = { "app.kubernetes.io/instance" = local.name } }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = local.peer_orgs
        content {
          namespace_selector { match_labels = { (var.namespace_org_label) = from.value } }
        }
      }
    }
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  count = module.org.has_org ? 1 : 0
  metadata {
    name      = "${local.name}-home"
    namespace = module.org.namespace
    labels    = local.labels
  }
  wait_until_bound = false
  spec {
    access_modes = ["ReadWriteOnce"]
    resources { requests = { storage = "5Gi" } }
  }
}

resource "kubernetes_deployment_v1" "main" {
  count            = data.coder_workspace.me.start_count
  wait_for_rollout = false
  depends_on       = [kubernetes_persistent_volume_claim_v1.home, kubernetes_network_policy_v1.workspace, module.org]

  metadata {
    name      = local.name
    namespace = module.org.namespace
    labels    = local.labels
  }

  spec {
    replicas = 1
    strategy { type = "Recreate" }
    selector { match_labels = { "app.kubernetes.io/instance" = local.name } }

    template {
      metadata { labels = local.labels }
      spec {
        node_selector                   = module.org.node_selector
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
            limits   = { cpu = "2", memory = "2Gi" }
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
          persistent_volume_claim { claim_name = try(kubernetes_persistent_volume_claim_v1.home[0].metadata[0].name, "") }
        }
      }
    }
  }
}
