# RUNBOOK — cómo retomar este laboratorio

Este documento es la memoria de lo que ya se probó y funcionó en este POC
(Azure + Terraform + AKS + ACR + 4 apps + Jenkins VM), para que cualquiera
(o cualquier sesión de Claude Code) pueda retomarlo sin repetir los mismos
errores que ya resolvimos.

## Estado de la infraestructura

Puede estar en 3 estados distintos. Verificar antes de asumir nada:

```bash
az aks show --name aks-devops-lab --resource-group rg-devops-lab --query "powerState" -o tsv 2>&1
az vm get-instance-view --name vm-jenkins --resource-group rg-devops-lab --query "instanceView.statuses[1].displayStatus" -o tsv 2>&1
```

- Si ambos comandos fallan con `ResourceGroupNotFound` / `ResourceNotFound` → todo fue destruido (`terraform destroy`). Hay que crear todo de cero (sección "Desde cero" abajo).
- Si dicen `Stopped` / `VM deallocated` → está pausado para no facturar cómputo. Retomar con la sección "Reanudar desde pausa".
- Si dicen `Running` → ya está todo arriba, ir directo a la sección "Verificar que las apps respondan".

## Datos fijos del entorno

| Recurso | Valor |
|---|---|
| Resource Group | `rg-devops-lab` (eastus2) |
| ACR | `devopslab01acr` (`devopslab01acr.azurecr.io`) — el nombre `devopslabacr` que se pidió originalmente **ya estaba tomado globalmente**, por eso el `01`. |
| AKS | `aks-devops-lab`, 1 nodo `Standard_D2s_v3` |
| VM Jenkins | `vm-jenkins`, `Standard_D2s_v3`, Ubuntu 22.04, usuario `azureuser` |
| Clave SSH de la VM | `~/.ssh/devops_lab_rsa` (RSA — ver gotcha #1) |
| Suscripción | la tuya — `az account show --query id -o tsv` |
| Repo apps | `POC-DEVOPS/api-node`, `mfe-consultas`, `mfe-reportes`, `shell-app` (siblings de `infra-devops-lab/`) |

La IP pública del Ingress **no es fija** (LoadBalancer dinámico): siempre volver a consultarla con:
```bash
kubectl get svc -n ingress-nginx ingress-nginx-controller
```
La última vez fue `<IP_DEL_INGRESS>`, pero si se reinstala ingress-nginx o se recrea el cluster, **cambia** — y hay que reconstruir las 3 imágenes de frontend (ver gotcha #4).

## Gotchas ya resueltos (no perder tiempo redescubriéndolos)

1. **Azure no acepta claves SSH ed25519** en `admin_ssh_key` de `azurerm_linux_virtual_machine`, solo RSA. Se generó `~/.ssh/devops_lab_rsa`. Si esa clave no existe en la máquina donde se retoma esto, generarla de nuevo con `ssh-keygen -t rsa -b 4096 -f ~/.ssh/devops_lab_rsa -N ""` y actualizar `terraform.tfvars` / `ssh_public_key_path`.

2. **`Standard_B2s` está bloqueado para esta suscripción en `eastus2`** (`NotAvailableForSubscription`, no es un tema de capacidad transitoria). Se usa `Standard_D2s_v3` en su lugar, tanto para el nodo de AKS como para la VM de Jenkins (`variables.tf`: `aks_node_vm_size`, `jenkins_vm_size`).

3. **AKS con `network_plugin = "azure"` pisa el rango de la propia VNet**: por default, el `service_cidr` que asigna Azure es `10.0.0.0/16`, igual al de nuestra VNet → error `ServiceCidrOverlapExistingSubnetsCidr`. Se fijó explícitamente en `main.tf`:
   ```
   network_profile {
     network_plugin = "azure"
     service_cidr   = "172.16.0.0/16"
     dns_service_ip = "172.16.0.10"
   }
   ```

4. **Las URLs de los microfrontends quedan "horneadas" dentro del JS en el momento del `docker build`, no se leen en runtime** (esto rompió el primer despliegue: shell y micro-frontends cargaban pero el contenido quedaba en blanco):
   - `shell-app` usa Module Federation (`next.config.js`): el navegador del usuario baja `remoteEntry.js` directo desde `CONSULTAS_URL`/`REPORTES_URL`. Tienen que ser una URL que el **navegador** pueda resolver — nunca un nombre interno de Kubernetes (`http://mfe-consultas`) ni `localhost`.
   - `mfe-consultas` y `mfe-reportes` usan `API_URL` (vía `webpack.DefinePlugin`) para hacer `fetch()` **desde el navegador** hacia `api-node`. Mismo problema.
   - Fix: pasarlas como `--build-arg` apuntando a la **IP pública del Ingress**, no a nombres de Service internos:
     ```bash
     PUBLIC=http://<IP_DEL_INGRESS>
     docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api -t $ACR/mfe-consultas:manualN ./mfe-consultas
     docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api -t $ACR/mfe-reportes:manualN ./mfe-reportes
     docker build --platform linux/amd64 --build-arg CONSULTAS_URL=$PUBLIC/consultas --build-arg REPORTES_URL=$PUBLIC/reportes -t $ACR/shell-app:manualN ./shell-app
     ```
   - Poner esas variables como `env:` en el Deployment de Kubernetes (como se hizo al principio) **no sirve para nada** en estos 3 casos — no sirve más que como documentación. `api-node` es la única app sin este problema (no tiene URLs de otros servicios baked in).

5. **El Mac de desarrollo es Apple Silicon (arm64), los nodos de AKS son x86_64**: todo `docker build` necesita `--platform linux/amd64` o los pods fallan al arrancar (`exec format error`).

6. **El Ingress necesita separarse en dos recursos**, no uno solo con 4 paths:
   - `apps-ingress-prefixed`: `/api`, `/consultas`, `/reportes`, con `nginx.ingress.kubernetes.io/rewrite-target: /$2` + `use-regex: "true"` + paths tipo `/api(/|$)(.*)`, porque esos backends no conocen el prefijo (p. ej. `api-node` solo tiene la ruta `/health`, no `/api/health`).
   - `apps-ingress-root`: solo `/` → `shell-app`, **sin** rewrite-target, porque Next.js necesita ver la ruta completa para sus assets (`/_next/...`).
   - Ambos viven en `k8s/ingress.yaml` (documento YAML con `---`).

7. **Nombre del ACR debe ser único globalmente en Azure** (no solo en la suscripción). Se verifica con `az acr check-name --name <nombre>`.

8. **La clave GPG publicada de Jenkins (`jenkins.io-2023.key`) falla la verificación vía `apt-key`** en Ubuntu 22.04 incluso trayendo la clave correcta (`7198F4B714ABFC68`) y dearmoreada — confirmado con `gpgv` manual funcionando bien, así que es un bug de compatibilidad de `apt-key`, no de la clave. `cloud-init.yaml` ya usa `deb [trusted=yes] https://pkg.jenkins.io/debian-stable binary/` como workaround (se sigue bajando por HTTPS del dominio oficial).

9. **El Jenkins LTS actual requiere Java 21**, no Java 17 (el servicio queda en `Failed with result 'exit-code'` con el log `Running with Java 17 ... older than the minimum required version`). `cloud-init.yaml` instala `openjdk-21-jre-headless` y hace `update-alternatives --set java` a esa versión antes de arrancar Jenkins. Si el servicio no arranca después de instalar Java 21, correr `sudo systemctl reset-failed jenkins` primero (systemd rate-limitea los reintentos fallidos previos).

10. **La VM de Jenkins nunca tuvo Node.js/npm instalado**: los `Jenkinsfile` corren `npm ci`/`npm test` directo en el agente (`agent any`, sin contenedor), así que sin Node el stage "Install & Test" falla con `npm: not found` (exit code 127) apenas arranca el primer pipeline. `cloud-init.yaml` ya instala `nodejs` (v20, vía NodeSource) después de Docker. Si una VM existente no lo tiene: `curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash - && sudo apt-get install -y nodejs`.

11. **El GitHub Branch Source plugin (para Multibranch Pipeline) solo acepta credenciales tipo "Username with password"** para el repo, no "Secret text" — aunque el PAT sea el mismo. Hay que crear una credencial separada (usada solo para esto) con Username = tu usuario de GitHub y Password = el PAT con scope `repo`. Si el "Validate" del job da `404 Not Found` de la API de GitHub en un repo privado, es casi siempre el PAT sin el scope/acceso correcto (probar con `curl -H "Authorization: token $PAT" https://api.github.com/repos/<owner>/<repo>` para aislarlo del lado de Jenkins).

## Tags de imagen actuales

Las 4 imágenes están en `devopslab01acr.azurecr.io`. Desde que el pipeline de Jenkins quedó andando (ver abajo), los tags son el `${BUILD_NUMBER}` de cada job + `latest` — ya no los tags manuales `:manual`/`:manual2` del día 1 (esos quedan solo como referencia histórica). Para ver el tag corriendo ahora mismo en cada deployment: `kubectl get deployment <app> -o jsonpath='{.spec.template.spec.containers[0].image}'`.

## Reanudar desde pausa (`az aks stop` / `az vm deallocate`)

```bash
az aks start --name aks-devops-lab --resource-group rg-devops-lab
az vm start --name vm-jenkins --resource-group rg-devops-lab

az aks get-credentials --resource-group rg-devops-lab --name aks-devops-lab --overwrite-existing
kubectl get nodes
kubectl get pods
```

Si el Ingress conserva la misma IP pública (probable si no se tocó nada), no hace falta reconstruir imágenes: saltar directo a "Verificar que las apps respondan". Si la IP cambió, ir a "Desde cero" solo para el paso de rebuild/push/apply de las 3 imágenes de frontend con la nueva IP.

## Desde cero (si se corrió `terraform destroy`)

```bash
cd infra-devops-lab
terraform init
terraform plan -out=tfplan
terraform apply "tfplan"

az aks get-credentials --resource-group rg-devops-lab --name aks-devops-lab

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx --namespace ingress-nginx --create-namespace
kubectl get svc -n ingress-nginx ingress-nginx-controller -w   # anotar la EXTERNAL-IP
```

Luego build & push (reemplazando `<IP>` por la EXTERNAL-IP de arriba) — ver comandos completos en el gotcha #4 y #5 — y:

```bash
cd infra-devops-lab
find k8s -name deployment.yaml -exec sed -i '' "s#<ACR_LOGIN_SERVER>#devopslab01acr.azurecr.io#g" {} +
kubectl apply -f k8s/api-node/ -f k8s/mfe-consultas/ -f k8s/mfe-reportes/ -f k8s/shell-app/ -f k8s/ingress.yaml
```

## Verificar que las apps respondan

```bash
IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sI http://$IP/
curl -sI http://$IP/api/health
curl -sI http://$IP/consultas
curl -sI http://$IP/reportes
```

Las 4 deben dar `200 OK`. Si `/consultas`/`/reportes` cargan pero el contenido queda en blanco, es el gotcha #4 (rebuild con la IP correcta).

## Apagar todo al terminar

Pausa (barato, conserva todo):
```bash
az aks stop --name aks-devops-lab --resource-group rg-devops-lab
az vm deallocate --name vm-jenkins --resource-group rg-devops-lab
```

Borrado total (costo cero, hay que rehacer todo):
```bash
terraform destroy
```

## Estado de Jenkins (Fase 3 — completa)

Jenkins está instalado y corriendo en `vm-jenkins` (systemd `jenkins.service`, habilitado — arranca solo cuando la VM prende). Instalación hecha a mano por SSH después de que el `cloud-init.yaml` original fallara en el primer boot (gotchas #8, #9 y #10 arriba); el `cloud-init.yaml` del repo ya quedó corregido para la próxima VM que se cree desde cero.

Wizard inicial hecho, plugins instalados (suggested + Docker Pipeline, Azure Credentials, Kubernetes CLI, GitHub Integration).

**Credenciales creadas** (Manage Jenkins → Credentials → Global):
- `acr-creds` (Username/Password): admin del ACR (`az acr credential show --name devopslab01acr` si hace falta regenerar).
- `kubeconfig-aks` (Secret file): `infra-devops-lab/aks-kubeconfig` (gitignored; regenerar con `az aks get-credentials --resource-group rg-devops-lab --name aks-devops-lab --file infra-devops-lab/aks-kubeconfig --overwrite-existing` si no existe).
- `github-token` (Secret text): PAT con scope `repo` — **no se usa en los jobs Multibranch** (ver gotcha #11), queda ahí sin uso activo.
- `github-pat` (Username with password, username=`Rxcxrdx`, password=el PAT): esta es la que realmente usan los 4 jobs Multibranch Pipeline (GitHub Branch Source Plugin solo acepta este tipo — gotcha #11).

**Jenkinsfile**: en los 4 repos (`api-node/Jenkinsfile`, `mfe-consultas/Jenkinsfile`, `mfe-reportes/Jenkinsfile`, `shell-app/Jenkinsfile`, todos en la rama `dev`), pipeline declarativo con 5 stages (Checkout, Install & Test, Build imagen, Push a ACR, Deploy a AKS). Notas:
- `shell-app` no tiene script `test` en su `package.json` → ese stage se saltea con un echo en vez de romper el pipeline.
- `mfe-consultas`, `mfe-reportes` y `shell-app` resuelven la IP pública del Ingress **en vivo con `kubectl`** dentro del stage de build (no hardcodeada), porque hornean esa URL en el bundle (gotcha #4).
- La VM necesitó Node.js 20 instalado a mano para que corriera `npm ci`/`npm test` (gotcha #10).

**Jobs Multibranch Pipeline + webhooks**: los 4 repos tienen su job en Jenkins apuntando a `https://github.com/Rxcxrdx/<repo>` con la credencial `github-pat`, y su webhook en GitHub (`http://<IP_DE_LA_VM_JENKINS>:8080/github-webhook/`, evento push). Confirmado funcionando: push a `dev` en cualquiera de los 4 dispara el build solo, sin entrar a Jenkins.

Hito cumplido: los 4 pipelines corrieron de punta a punta (tests → build → push a ACR → deploy a AKS) disparados por push a GitHub. Última verificación: los 4 pods `Running` con las imágenes de Jenkins (`api-node:3`, `mfe-consultas:1`, `mfe-reportes:1`, `shell-app:2` al momento de escribir esto — van a subir con cada push nuevo) y las 4 rutas del ingress respondiendo `200 OK`.

### Qué falta (no es parte del plan original, evaluar si se quiere)
- Nada crítico pendiente del plan de 2 días. Ideas para profundizar si se sigue con esto: notificaciones de Jenkins (Slack/email) en vez de solo el `echo` en el log; mover `acr-creds`/kubeconfig a algo más seguro que Basic Auth/admin habilitado en el ACR; agregar un stage de lint; y decidir si vale la pena mover el resolve-de-IP-del-ingress a un DNS/hostname fijo en vez de la IP dinámica del LoadBalancer.
