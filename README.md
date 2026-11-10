# homelab

k3s + ArgoCD (app of apps), GitOps puro. Acesso **só pela tailnet** `tailb0d602.ts.net` (nenhum serviço exposto na internet).

## Estrutura

```
root-app/root-app.yml       # Application única que sincroniza argo-apps/
argo-apps/*.yml             # app of apps: um Application por serviço (chart Helm ou path deste repo)
apps/<serviço>/             # manifests do serviço: deployment, service, ingress
bootstrap/bootstrap-argocd.sh  # instalação limpa do ArgoCD + root-app
out-of-business/            # configs aposentadas, não sincronizadas por nada
```

## Acesso

| URL | O que é |
|---|---|
| https://m-nginx.tailb0d602.ts.net | nginx de teste (`apps/nginx`) |
| https://argocd.tailb0d602.ts.net | ArgoCD UI/CLI |
| https://rustfs.tailb0d602.ts.net | console web do RustFS |
| https://rustfs-s3.tailb0d602.ts.net | API S3 do RustFS |
| https://argo.tailb0d602.ts.net | Argo Workflows UI (L3/TCP, cert self-signed do argo-server — aceite o aviso) |
| http://eniac.tailb0d602.ts.net | Traefik do k3s no node `eniac` (sem app, retorna 404) |

Cada app tem seu próprio device na tailnet, criado pelo Tailscale operator — não existe subdomínio dentro de `eniac.tailb0d602.ts.net` (MagicDNS só resolve `<device>.tailb0d602.ts.net`).

## Padrão de Ingress para serviço novo

Um Ingress `tailscale` por serviço (`apps/<serviço>/ingress.yml`). DNS e certificado Let's Encrypt são automáticos.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: <serviço> # irrelevante para o DNS
spec:
  ingressClassName: tailscale
  tls:
    - hosts:
        - <nome> # ÚNICO label -> https://<nome>.tailb0d602.ts.net
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: <serviço>
                port:
                  number: 80
```

Regras do operator (quebram silenciosamente se ignoradas):

- `tls.hosts[0]` **é** o hostname, e só o primeiro label conta (`m-nginx`, não `m-nginx.tailb0d602.ts.net`).
- Não use `rules[].host`: o roteamento é catch-all.
- Só HTTPS (443) e só `pathType: Prefix`.
- 1 device por Ingress; `ProxyGroup` não é usado aqui (bug de DNAT com kube-proxy nftables no k3s, tailscale#18338).
- Use `traefik` só quando quiser um path dentro de `eniac` ou HTTP puro — e lembrando que o Traefik **não** remove prefixo.

## Instalação limpa

Pré-requisitos, fora do Git (admin do Tailscale):

1. OAuth client em *Trust credentials* com **write** em `Devices/Core`, `Keys/Auth Keys` e `General/Services`, tag `tag:k8s-operator`. Sem `Auth Keys` o operator morre com `creating operator authkey: not found (404)`.
2. ACL: `"tagOwners": { "tag:k8s-operator": [], "tag:k8s": ["tag:k8s-operator"] }`.
3. *DNS → HTTPS Certificates* habilitado.

Depois:

```bash
export TS_OAUTH_CLIENT_ID=... TS_OAUTH_CLIENT_SECRET=...
./bootstrap/bootstrap-argocd.sh
```

O script cria o secret `operator-oauth`, instala o ArgoCD `v3.5.6` (`--server-side`), aplica `server.insecure=true`, espera os deployments e aplica o `root-app` — que traz operator, nginx, cert-manager e o Ingress do ArgoCD.

Senha do admin: `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`

## RustFS

`apps/rustfs` é wrapper do chart oficial (`charts.rustfs.com`, versão pinada no `Chart.yaml`) em modo **standalone** no namespace `rustfs`: o modo distributed (default do chart) exige ≥ 2 nodes e anti-affinity por hostname, então não agenda em um k3s de um node.

A credencial não fica no git. Crie o secret **antes** do primeiro sync (o chart exige `existingSecret` e falha no render sem chaves):

```bash
kubectl create namespace rustfs --dry-run=client -o yaml | kubectl apply -f -
kubectl -n rustfs create secret generic rustfs-credentials \
  --from-literal=RUSTFS_ACCESS_KEY=... \
  --from-literal=RUSTFS_SECRET_KEY=...
```

Sem ele o pod fica em `CreateContainerConfigError`.

## Gotchas

- **`server.insecure=true` é obrigatório** no `argocd-cmd-params-cm`: o Ingress do operator só fala HTTP com o backend, então sem isso o ArgoCD responde `307 → https` e o proxy volta pra porta 80 (loop). Esse patch é drift manual — o ArgoCD não se gerencia por aqui.
- **CRDs grandes** (operator Tailscale ~460 KB) exigem `ServerSideApply=true` no Application, senão o sync falha no limite de 256 KB do apply client-side.
- **Argo Workflows**: instalado por `manifests/cluster-install` (kustomize, workflows cluster-wide), não pelo `quick-start-minimal.yaml` — o release tem 12 MB e o repo-server recusa source do tipo `directory` acima de 10 MB (`exceeded max combined manifest file size`). Files de kustomize não passam por esse cap.
- O `argo-server` roda com TLS em 2746 e o Ingress do operator só fala HTTP com o backend, por isso o Argo Workflows é exposto por Service **L3** (`loadBalancerClass: tailscale`), não por Ingress.
- O nginx monta um único `index.html` via ConfigMap; servir em subpath daria 404 porque o prefixo não é removido. Por isso `path: /`.
- `argocd-server` tem `type: ClusterIP` **declarado** em `apps/argocd/service-argocd-server.yml`. Se voltar para `LoadBalancer`, o k3s cria um DaemonSet `svclb-argocd-server` com `hostPort` 80/443, que conflita com o `svclb-traefik` na única node e deixa um pod em `Pending` (`didn't have free ports`) — o `selfHeal` do app `argocd-ingress` desfaz a mudança.
