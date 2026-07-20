# k8s/

Manifiestos de las 4 apps + Ingress para el AKS del laboratorio.

## 1. Instalar ingress-nginx en el cluster

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace
```

Espera a que el Service `ingress-nginx-controller` (LoadBalancer) tenga una
IP pública asignada:

```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

## 2. Reemplazar el placeholder de imagen

Todos los Deployments usan `<ACR_LOGIN_SERVER>/<app>:latest` como
placeholder. Reemplázalo (a mano para pruebas, o en el pipeline de Jenkins)
por el login server real del ACR, por ejemplo:

```bash
ACR_LOGIN_SERVER=$(terraform -chdir=.. output -raw acr_login_server)
find . -name deployment.yaml -exec sed -i '' "s#<ACR_LOGIN_SERVER>#${ACR_LOGIN_SERVER}#g" {} +
```

(en Linux, sin macOS/BSD sed, quita el `''` después de `-i`).

## 3. Aplicar los manifiestos

```bash
kubectl apply -f api-node/
kubectl apply -f mfe-consultas/
kubectl apply -f mfe-reportes/
kubectl apply -f shell-app/
kubectl apply -f ingress.yaml
```

## 4. Rutas expuestas por el Ingress

| Path         | Service        | Puerto |
|--------------|----------------|--------|
| `/`          | shell-app      | 3000   |
| `/api`       | api-node       | 3001   |
| `/consultas` | mfe-consultas  | 80     |
| `/reportes`  | mfe-reportes   | 80     |

`shell-app` recibe `CONSULTAS_URL=http://mfe-consultas` y
`REPORTES_URL=http://mfe-reportes` (DNS interno del cluster, mismo
namespace) vía variables de entorno en su Deployment.

Nota: si las apps servidas por `mfe-consultas` / `mfe-reportes` esperan
recibir las requests sin el prefijo (`/consultas`, `/reportes`) por delante,
agrega `nginx.ingress.kubernetes.io/rewrite-target: /$2` y ajusta los
`path` a formato regex (`/consultas(/|$)(.*)`) en `ingress.yaml`.
