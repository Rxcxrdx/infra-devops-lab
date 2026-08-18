# k8s/

Kubernetes manifests for the four applications, plus the Ingress resources.

## 1. Install ingress-nginx

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

Wait for the `ingress-nginx-controller` LoadBalancer to be assigned a public IP:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

## 2. Replace the image placeholder

Every deployment uses `<ACR_LOGIN_SERVER>/<app>:latest` as a placeholder.
Replace it with the real registry login server:

```bash
ACR_LOGIN_SERVER=$(terraform -chdir=.. output -raw acr_login_server)
find . -name deployment.yaml -exec sed -i '' "s#<ACR_LOGIN_SERVER>#${ACR_LOGIN_SERVER}#g" {} +
```

On Linux, drop the `''` after `-i` — that argument is BSD/macOS specific.

## 3. Apply the manifests

```bash
kubectl apply -f api-node/
kubectl apply -f mfe-consultas/
kubectl apply -f mfe-reportes/
kubectl apply -f shell-app/
kubectl apply -f ingress.yaml
```

## 4. Ingress routes

| Path | Service | Port |
|:--|:--|:--|
| `/` | shell-app | 3000 |
| `/api` | api-node | 3001 |
| `/consultas` | mfe-consultas | 80 |
| `/reportes` | mfe-reportes | 80 |

Routing is split across two Ingress resources in `ingress.yaml`:

- **`apps-ingress-prefixed`** handles `/api`, `/consultas`, and `/reportes`
  using `rewrite-target: /$2` with regex paths, because those backends do not
  know about their path prefix — `api-node` serves `/health`, not `/api/health`.
- **`apps-ingress-root`** routes `/` to the host application **without**
  rewriting, because Next.js needs the full path to serve its assets under
  `/_next/`.

A single Ingress with a global rewrite breaks the host application's asset
paths, which is why the two are kept separate.

## Frontend URLs are baked in at build time

The `CONSULTAS_URL`, `REPORTES_URL`, and `API_URL` values listed as `env:`
entries in the deployment manifests are **documentation only** — they have no
runtime effect.

`shell-app` inlines its remote URLs through `next.config.js`, and the two
micro-frontends inline `API_URL` through `webpack.DefinePlugin`. Both happen
during `docker build`. Because the **browser** is what fetches those URLs, they
must point at the public ingress address — never at an internal cluster DNS
name such as `http://mfe-consultas`:

```bash
PUBLIC=http://<ingress-ip>

docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api \
  -t $ACR_LOGIN_SERVER/mfe-consultas:<tag> ../../mfe-consultas
docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api \
  -t $ACR_LOGIN_SERVER/mfe-reportes:<tag> ../../mfe-reportes
docker build --platform linux/amd64 \
  --build-arg CONSULTAS_URL=$PUBLIC/consultas \
  --build-arg REPORTES_URL=$PUBLIC/reportes \
  -t $ACR_LOGIN_SERVER/shell-app:<tag> ../../shell-app
```

If the ingress IP changes, these three images have to be rebuilt and pushed
again. `api-node` is unaffected — it holds no URLs of other services.
