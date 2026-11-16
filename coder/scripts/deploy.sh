#!/usr/bin/env bash
# Deploys Postgres + Keycloak (test IdP) + Coder OSS into the "coder" namespace.
# Idempotent: generated secrets are kept if they already exist.
set -euo pipefail
cd "$(dirname "$0")/.."

kubectl create namespace coder --dry-run=client -o yaml | kubectl apply -f -

gen() { python3 -c 'import secrets;print(secrets.token_urlsafe(24))'; }
getsec() { kubectl -n coder get secret "$1" -o "jsonpath={.data.$2}" 2>/dev/null | base64 -d; }

PG_PASS=$(getsec postgres password || true);            PG_PASS=${PG_PASS:-$(gen)}
OIDC_SECRET=$(getsec coder-oidc client-secret || true);  OIDC_SECRET=${OIDC_SECRET:-$(gen)}
USER_PASSWORD=$(getsec demo-users password || true);     USER_PASSWORD=${USER_PASSWORD:-$(gen)}
KC_ADMIN=$(getsec keycloak-realm admin-password || true); KC_ADMIN=${KC_ADMIN:-$(gen)}
ADMIN_PASS=$(getsec demo-users coder-admin-password || true); ADMIN_PASS=${ADMIN_PASS:-$(gen)}

apply_secret() { kubectl -n coder create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -; }
apply_secret postgres --from-literal=password="$PG_PASS"
apply_secret coder-db-url --from-literal=url="postgres://coder:${PG_PASS}@postgres.coder.svc:5432/coder?sslmode=disable"
apply_secret coder-oidc --from-literal=client-secret="$OIDC_SECRET"
apply_secret demo-users --from-literal=password="$USER_PASSWORD" --from-literal=coder-admin-password="$ADMIN_PASS"
apply_secret keycloak-realm --from-literal=admin-password="$KC_ADMIN" \
  --from-literal=realm.json="$(OIDC_SECRET=$OIDC_SECRET USER_PASSWORD=$USER_PASSWORD envsubst < deploy/realm.json.tmpl)"

kubectl apply -f deploy/postgres.yaml -f deploy/keycloak.yaml
kubectl -n coder rollout status statefulset/postgres --timeout=180s
kubectl -n coder rollout status deployment/keycloak --timeout=300s

helm repo add coder-v2 https://helm.coder.com/v2 >/dev/null 2>&1 || true
helm upgrade --install coder coder-v2/coder --version 2.39.1 -n coder -f deploy/coder-values.yaml --wait --timeout 5m
