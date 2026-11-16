terraform {
  required_providers {
    coder      = { source = "coder/coder", version = "~> 2.20" }
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.38" }
    http       = { source = "hashicorp/http", version = "~> 3.5" }
  }
}

# Org-mapping settings, all admin-only (set at push time with --variable or
# --variables-file; users never see them). See modules/org-mapping/README.md.

variable "namespace_pattern" {
  type        = string
  default     = "<org>-zoned-workspaces"
  description = "Namespace for an organisation; <org> is replaced. Organisations without an existing namespace are refused. E.g. test-<org> when testing."
}

variable "support_contact" {
  type        = string
  default     = "your Coder administrator"
  description = "Who users should contact, shown in organisation error messages."
}

variable "namespace_org_label" {
  type        = string
  default     = "coder.demo/org"
  description = "Label the namespace must carry with the organisation as its value. Empty to check existence only."
}

variable "node_label_pattern" {
  type        = string
  default     = "coder.demo/org-<org>"
  description = "Node label key for the organisation's nodes; <org> is replaced. Empty for no node selector."
}

variable "org_label_key" {
  type        = string
  default     = "coder.demo/org"
  description = "Label key carrying the organisation on workspace resources. Empty to omit."
}

variable "claim_source" {
  type        = string
  default     = "userinfo"
  description = "Where to read the claims: \"userinfo\" or \"access_token\"."
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

variable "organisation_name_regex" {
  type        = string
  default     = "^[a-z0-9]([-a-z0-9]{0,40}[a-z0-9])?$"
  description = "Claim values not matching this are ignored."
}

variable "lowercase_organisations" {
  type        = bool
  default     = true
  description = "Lower-case claim values before matching."
}

variable "groups_claim" {
  type        = string
  default     = "groups"
  description = "Name of the claim holding the user's groups."
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

variable "require_organisation" {
  type        = bool
  default     = true
  description = "Fail starts when the workspace has no supported organisation."
}

variable "recheck_on_start" {
  type        = bool
  default     = true
  description = "Fail starts when the user is no longer in the workspace's organisation."
}

# Workspace pods may only reach Coder through its in-cluster Service (see
# tenancy/zoned-orgs.yaml), so the access URL's hostname is pinned to the
# Service's ClusterIP. Empty disables the alias.
variable "coder_service_ip" {
  type        = string
  default     = "10.43.255.180"
  description = "ClusterIP of the coder Service: kubectl -n coder get svc coder -o jsonpath='{.spec.clusterIP}'."
}

# In-cluster config: the provisioner runs inside the Coder pod as SA coder/coder.
provider "kubernetes" {}

data "coder_provisioner" "me" {}
data "coder_workspace" "me" {}
data "coder_workspace_owner" "me" {}

# Resolves the organisation from the claim and the namespaces that exist, pins
# it, and fails starts with no supported organisation.
module "org" {
  source                  = "./modules/org-mapping"
  namespace_pattern       = var.namespace_pattern
  support_contact         = var.support_contact
  namespace_org_label     = var.namespace_org_label
  node_label_pattern      = var.node_label_pattern
  org_label_key           = var.org_label_key
  claim_source            = var.claim_source
  userinfo_url            = var.oidc_userinfo_url
  organisations_claim     = var.organisations_claim
  organisation_name_regex = var.organisation_name_regex
  lowercase_organisations = var.lowercase_organisations
  groups_claim            = var.groups_claim
  group_pattern           = var.group_pattern
  group_names             = jsondecode(var.group_names)
  require_organisation    = var.require_organisation
  recheck_on_start        = var.recheck_on_start
}

# The pin used to live in this template.
moved {
  from = terraform_data.org
  to   = module.org.terraform_data.org
}

locals {
  org        = module.org.organisation
  namespace  = module.org.namespace
  coder_host = regex("^https?://([^:/]+)", data.coder_workspace.me.access_url)[0]
  name       = "coder-${data.coder_workspace.me.id}"
  labels = merge(module.org.labels, {
    "app.kubernetes.io/name"     = "coder-workspace"
    "app.kubernetes.io/instance" = local.name
    "com.coder.workspace.id"     = data.coder_workspace.me.id
    "com.coder.user.username"    = data.coder_workspace_owner.me.name
  })
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
    display_name = "Egress zone"
    key          = "zone"
    script       = "echo \"$EGRESS_ZONE via $HTTPS_PROXY\""
    interval     = 0
  }
}

resource "kubernetes_persistent_volume_claim_v1" "home" {
  count = module.org.has_org ? 1 : 0
  metadata {
    name      = "${local.name}-home"
    namespace = local.namespace
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
  depends_on       = [kubernetes_persistent_volume_claim_v1.home, module.org]

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
        node_selector                   = module.org.node_selector
        automount_service_account_token = false
        enable_service_links            = false

        dynamic "host_aliases" {
          for_each = var.coder_service_ip == "" ? [] : [1]
          content {
            ip        = var.coder_service_ip
            hostnames = [local.coder_host]
          }
        }

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
          # HTTP(S)_PROXY, NO_PROXY and EGRESS_ZONE for the namespace's zone,
          # set by the cluster admin (tenancy/zoned-orgs.yaml).
          env_from {
            config_map_ref { name = "egress-proxy" }
          }
          # For the future auth proxy: a short-lived token identifying this
          # pod (and so its namespace and workspace), checkable with TokenReview.
          env {
            name  = "EGRESS_PROXY_TOKEN_FILE"
            value = "/var/run/secrets/egress-proxy/token"
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
          volume_mount {
            name       = "egress-proxy-token"
            mount_path = "/var/run/secrets/egress-proxy"
            read_only  = true
          }
        }

        volume {
          name = "home"
          persistent_volume_claim { claim_name = try(kubernetes_persistent_volume_claim_v1.home[0].metadata[0].name, "") }
        }
        volume {
          name = "egress-proxy-token"
          projected {
            sources {
              service_account_token {
                audience           = "egress-proxy"
                expiration_seconds = 3600
                path               = "token"
              }
            }
          }
        }
      }
    }
  }
}
