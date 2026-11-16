# Maps a Coder workspace owner to an organisation and namespace (Coder OSS).
#
#   1. Takes the owner's organisations as a list, from anywhere; usually an
#      OIDC claim read with ../oidc-claims:
#        organisations = lookup(module.oidc.lists, "organisations", [])
#   2. Turns each organisation into a namespace with
#      namespace_pattern (e.g. "test-<org>"). An organisation is supported
#      when that namespace exists (and, if namespace_org_label is set, is
#      labelled with the organisation). The first supported one, in
#      alphabetical order, is used.
#   3. Pins the organisation and namespace on the first build, so claim or
#      pattern changes never move a workspace.
#   4. On start, fails the build when the user has no supported organisation,
#      or is no longer in the pinned one. Stop and delete never check.
#
# Gate resources that must not exist without an organisation on `has_org`
# (known at plan):
#
#   count = module.org.has_org ? 1 : 0
#
# A workspace whose first build had no supported organisation pins "none": it
# never starts, and stop/delete succeed because nothing was created.
#
# Requires get on namespaces for the provisioner (tenancy/namespace-lookup.yaml).
#
# Files: main.tf (providers, data sources, resources), variables.tf,
# locals.tf, outputs.tf.

terraform {
  required_providers {
    coder      = { source = "coder/coder" }
    kubernetes = { source = "hashicorp/kubernetes" }
  }
}

data "coder_workspace" "me" {}

data "coder_workspace_owner" "me" {}

# Empty when var.organisations is (stop/delete with userinfo claims). A missing namespace reads as
# an empty uid rather than an error.
data "kubernetes_namespace_v1" "candidate" {
  for_each = local.ns_for
  metadata { name = each.value }
}

# input (not output) is read: it is known at plan, both on the first build and
# afterwards (ignore_changes keeps the stored value), so callers can use it in
# count.
resource "terraform_data" "org" {
  input = local.resolved
  lifecycle { ignore_changes = [input] }
}

# Pinned separately so a later namespace_pattern change does not move the
# workspace (and its volume) to another namespace.
resource "terraform_data" "namespace" {
  input = replace(var.namespace_pattern, "<org>", terraform_data.org.input)
  lifecycle { ignore_changes = [input] }
}

# Exists only while starting; its preconditions fail the plan, before the
# template creates anything.
resource "terraform_data" "start_check" {
  count = local.starting && !local.is_import ? 1 : 0
  input = local.org

  lifecycle {
    precondition {
      condition     = !var.require_organisation || local.has_org
      error_message = local.no_org_error
    }
    precondition {
      condition     = !var.recheck_on_start || !local.has_org || contains(local.orgs, local.org)
      error_message = local.removed_error
    }
  }
}
