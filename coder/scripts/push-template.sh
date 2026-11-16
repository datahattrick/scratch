#!/usr/bin/env bash
# Pushes templates/<dir> as a Coder template, with templates/<dir>/variables.yaml
# if present. Coder uploads symlinks as-is, so the template is copied with its
# modules/ symlink dereferenced first.
#
# Usage: scripts/push-template.sh <dir> [extra coder templates push args]
#   TEMPLATE_NAME  push under another name (default: <dir>), e.g. a test copy:
#                  TEMPLATE_NAME=egress-zoned-test scripts/push-template.sh egress-zoned --variable 'namespace_pattern=test-<org>'
#   CODER          coder binary (default: coder)
set -euo pipefail
cd "$(dirname "$0")/.."

dir=${1:?usage: $0 <template-dir> [coder push args]}
shift
[ -d "templates/$dir" ] || { echo "no such template: templates/$dir" >&2; exit 1; }
name=${TEMPLATE_NAME:-$dir}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
cp -rL "templates/$dir/." "$stage/"

vars=()
[ -f "templates/$dir/variables.yaml" ] && vars=(--variables-file "templates/$dir/variables.yaml")

"${CODER:-coder}" templates push "$name" -d "$stage" "${vars[@]}" --yes "$@"
