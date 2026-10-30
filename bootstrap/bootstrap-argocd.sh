#!/usr/bin/env bash
# Bootstrap limpo do homelab: ArgoCD + app-of-apps (root-app).
# Idempotente: pode rodar de novo sem quebrar nada.
#
# Uso:
#   TS_OAUTH_CLIENT_ID=xxx TS_OAUTH_CLIENT_SECRET=yyy ./bootstrap/bootstrap-argocd.sh
#
# O secret do Tailscale operator precisa existir ANTES, porque o root-app
# instala o operator e ele crasha sem as credenciais.
set -euo pipefail

ARGOCD_VERSION="v3.5.6"
REPO="https://github.com/garaujo94/homelab"
INSECURE="true" # TLS termina no proxy da tailnet (Ingress argocd.tailb0d602.ts.net)

echo "==> checando cluster"
kubectl cluster-info >/dev/null

echo "==> secret do tailscale operator"
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f - >/dev/null
if ! kubectl -n tailscale get secret operator-oauth >/dev/null 2>&1; then
  if [ -z "${TS_OAUTH_CLIENT_ID:-}" ] || [ -z "${TS_OAUTH_CLIENT_SECRET:-}" ]; then
    echo "ERRO: crie o secret operator-oauth (client_id/client_secret) ou exporte TS_OAUTH_CLIENT_ID e TS_OAUTH_CLIENT_SECRET" >&2
    exit 1
  fi
  kubectl -n tailscale create secret generic operator-oauth \
    --from-literal=client_id="${TS_OAUTH_CLIENT_ID}" \
    --from-literal=client_secret="${TS_OAUTH_CLIENT_SECRET}"
fi

echo "==> argocd ${ARGOCD_VERSION}"
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl apply -n argocd --server-side --force-conflicts -f "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

# server.insecure: o argocd-server serve HTTP em 8080 e o proxy da tailnet faz o TLS
# manifest.size: quick-start do argo-workflows tem 12MB (default do repo-server é 10M)
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge \
  -p "{\"data\":{\"server.insecure\":\"${INSECURE}\",\"reposerver.max.combined.directory.manifests.size\":\"30M\"}}"

kubectl -n argocd rollout restart deploy/argocd-server deploy/argocd-repo-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=600s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=600s
kubectl -n argocd wait --for=condition=available deployment --all --timeout=600s

echo "==> root-app (app of apps)"
kubectl apply -f "${REPO}/raw/HEAD/root-app/root-app.yml"

echo "==> pronto"
echo "UI:    https://argocd.tailb0d602.ts.net (após o operator subir + cert emitir)"
echo "admin: $(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo '(secret ainda não criado)')"
kubectl -n argocd get applications
