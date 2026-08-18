# Operations Runbook

Operational guide for provisioning, deploying, verifying, and tearing down the
lab environment, plus the known issues encountered while building it and how
each was resolved.

## Contents

- [Prerequisites](#prerequisites)
- [Checking the environment state](#checking-the-environment-state)
- [Provisioning from scratch](#provisioning-from-scratch)
- [Deploying the applications](#deploying-the-applications)
- [Verifying the deployment](#verifying-the-deployment)
- [Resuming a paused environment](#resuming-a-paused-environment)
- [Shutting down](#shutting-down)
- [Jenkins setup](#jenkins-setup)
- [Known issues and resolutions](#known-issues-and-resolutions)

---

## Prerequisites

| Requirement | Notes |
|:--|:--|
| Terraform | >= 1.7 |
| Azure CLI | Authenticated (`az login`) against an active subscription |
| SSH key | **RSA** — Azure rejects ed25519 for Linux VMs (see issue 1) |
| kubectl, Helm | For cluster access and ingress installation |
| Docker | With `linux/amd64` build support (see issue 5) |

Set the Terraform variables before applying:

```bash
cp terraform.tfvars.example terraform.tfvars
# set my_ip to your current public IP: curl ifconfig.me
```

---

## Checking the environment state

The environment can be in one of three states. Verify before assuming anything:

```bash
az aks show --name <cluster-name> --resource-group <resource-group> \
  --query "powerState" -o tsv 2>&1
az vm get-instance-view --name <vm-name> --resource-group <resource-group> \
  --query "instanceView.statuses[1].displayStatus" -o tsv 2>&1
```

| Result | State | Next step |
|:--|:--|:--|
| `ResourceGroupNotFound` / `ResourceNotFound` | Destroyed | [Provisioning from scratch](#provisioning-from-scratch) |
| `Stopped` / `VM deallocated` | Paused to avoid compute charges | [Resuming a paused environment](#resuming-a-paused-environment) |
| `Running` | Live | [Verifying the deployment](#verifying-the-deployment) |

---

## Provisioning from scratch

```bash
terraform init
terraform plan -out=tfplan
terraform apply "tfplan"

az aks get-credentials --resource-group <resource-group> --name <cluster-name>
```

Install the ingress controller and wait for its public IP:

```bash
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update
helm install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace

kubectl get svc -n ingress-nginx ingress-nginx-controller -w
```

Record the `EXTERNAL-IP` — the frontend images must be built against it (see
issue 4).

---

## Deploying the applications

Build and push the images, substituting the ingress IP:

```bash
PUBLIC=http://<ingress-ip>
REGISTRY=<registry>.azurecr.io

docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api \
  -t $REGISTRY/mfe-consultas:<tag> ../mfe-consultas
docker build --platform linux/amd64 --build-arg API_URL=$PUBLIC/api \
  -t $REGISTRY/mfe-reportes:<tag> ../mfe-reportes
docker build --platform linux/amd64 \
  --build-arg CONSULTAS_URL=$PUBLIC/consultas \
  --build-arg REPORTES_URL=$PUBLIC/reportes \
  -t $REGISTRY/shell-app:<tag> ../shell-app
docker build --platform linux/amd64 -t $REGISTRY/api-node:<tag> ../api-node

az acr login --name <registry>
docker push $REGISTRY/mfe-consultas:<tag>   # repeat for each image
```

Apply the manifests:

```bash
find k8s -name deployment.yaml -exec sed -i '' "s#<ACR_LOGIN_SERVER>#$REGISTRY#g" {} +
kubectl apply -f k8s/api-node/ -f k8s/mfe-consultas/ \
              -f k8s/mfe-reportes/ -f k8s/shell-app/ -f k8s/ingress.yaml
```

Once the Jenkins pipelines are configured, image tags come from the build
number rather than manual tags. To check what a deployment is currently
running:

```bash
kubectl get deployment <app> -o jsonpath='{.spec.template.spec.containers[0].image}'
```

---

## Verifying the deployment

```bash
IP=$(kubectl get svc -n ingress-nginx ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

curl -sI http://$IP/
curl -sI http://$IP/api/health
curl -sI http://$IP/consultas
curl -sI http://$IP/reportes
```

All four should return `200 OK`. If `/consultas` or `/reportes` respond but
render blank, the images were built against the wrong URL — see issue 4.

---

## Resuming a paused environment

```bash
az aks start --name <cluster-name> --resource-group <resource-group>
az vm start  --name <vm-name>      --resource-group <resource-group>

az aks get-credentials --resource-group <resource-group> \
  --name <cluster-name> --overwrite-existing
kubectl get nodes
kubectl get pods
```

If the ingress kept its public IP, no rebuild is needed. If the IP changed, the
three frontend images must be rebuilt and pushed against the new address
(issue 4).

---

## Shutting down

Pause — retains configuration, stops compute charges:

```bash
az aks stop      --name <cluster-name> --resource-group <resource-group>
az vm deallocate --name <vm-name>      --resource-group <resource-group>
```

Destroy — zero cost, everything must be rebuilt:

```bash
terraform destroy
```

---

## Jenkins setup

Jenkins runs as a systemd service on the VM, enabled to start on boot. The
`cloud-init.yaml` in this repository provisions Docker, Java 21, Node 20,
kubectl, and the Azure CLI.

**Plugins:** suggested set, plus Docker Pipeline, Azure Credentials,
Kubernetes CLI, and GitHub Integration.

**Credentials** (Manage Jenkins → Credentials → Global):

| ID | Type | Purpose |
|:--|:--|:--|
| `acr-creds` | Username/Password | Registry admin credentials — regenerate with `az acr credential show --name <registry>` |
| `kubeconfig-aks` | Secret file | Cluster kubeconfig — regenerate with `az aks get-credentials --file <path> --overwrite-existing` |
| `github-pat` | Username with password | Repository access for the Multibranch jobs (see issue 11) |

**Pipelines:** each application repository defines a declarative `Jenkinsfile`
on the `dev` branch with five stages — Checkout, Install & Test, Build image,
Push to registry, Deploy to AKS. Notes:

- The host application has no `test` script, so that stage logs a message
  instead of failing the pipeline.
- The three frontend pipelines resolve the ingress IP **live via `kubectl`**
  inside the build stage rather than hardcoding it, because that URL is baked
  into the bundle (issue 4).

**Multibranch jobs and webhooks:** each repository has a Multibranch Pipeline
job pointing at its GitHub URL with the `github-pat` credential, and a push
webhook targeting `http://<vm-ip>:8080/github-webhook/`. A push to `dev`
triggers the corresponding build automatically.

---

## Known issues and resolutions

Problems encountered while building this environment, with the resolution for
each.

### 1. Azure rejects ed25519 SSH keys

`azurerm_linux_virtual_machine.admin_ssh_key` accepts RSA only. Generate one:

```bash
ssh-keygen -t rsa -b 4096 -f ~/.ssh/<key-name> -N ""
```

Then point `ssh_public_key_path` at the `.pub` file.

### 2. `Standard_B2s` unavailable for the subscription

Provisioning fails with `NotAvailableForSubscription` in `eastus2` — this is a
subscription restriction, not transient capacity. `Standard_D2s_v3` is used
instead for both the AKS node and the Jenkins VM (`aks_node_vm_size`,
`jenkins_vm_size` in `variables.tf`).

### 3. AKS service CIDR overlaps the virtual network

With `network_plugin = "azure"`, Azure defaults `service_cidr` to `10.0.0.0/16`
— identical to the VNet range — producing
`ServiceCidrOverlapExistingSubnetsCidr`. Set both values explicitly:

```hcl
network_profile {
  network_plugin = "azure"
  service_cidr   = "172.16.0.0/16"
  dns_service_ip = "172.16.0.10"
}
```

### 4. Frontend URLs are resolved at build time, not runtime

**Symptom:** pages load but render blank.

The host application inlines its remote URLs through `next.config.js`, and both
micro-frontends inline `API_URL` through `webpack.DefinePlugin`. Both happen
during `docker build`. Two consequences:

- Setting these as `env:` entries on a Kubernetes deployment has **no effect**.
  They must be passed as `--build-arg` values.
- The **browser** is what fetches these URLs, so they must point at the public
  ingress address — never an internal cluster DNS name such as
  `http://mfe-consultas`, and never `localhost`.

If the ingress IP changes, the three frontend images must be rebuilt and
pushed. The API is unaffected, as it holds no URLs of other services.

### 5. Architecture mismatch between build host and cluster nodes

Building on an arm64 machine (Apple Silicon) produces images that fail on
x86_64 AKS nodes with `exec format error`. Every build needs
`--platform linux/amd64`.

### 6. A single Ingress with rewrite-target breaks the host application

`/api`, `/consultas`, and `/reportes` need their prefix stripped, because those
backends do not know about it — the API serves `/health`, not `/api/health`.
The host application needs the opposite: the full path, so Next.js can serve
assets under `/_next/`.

Resolved by splitting into two Ingress resources in `k8s/ingress.yaml`:
`apps-ingress-prefixed` with `rewrite-target: /$2` and `use-regex: "true"`,
and `apps-ingress-root` for `/` with no rewrite.

### 7. Registry names are globally unique

Azure Container Registry names must be unique across all of Azure, not just
within the subscription. A name that is already taken fails at apply time.

### 8. Jenkins GPG key fails apt-key verification on Ubuntu 22.04

The official `jenkins.io-2023.key` fails verification through `apt-key` even
when correctly dearmored — a compatibility issue, not a problem with the key.
`cloud-init.yaml` works around it using `deb [trusted=yes] ...`.

### 9. Current Jenkins LTS requires Java 21

With Java 17 the service fails to start, logging
`Running with Java 17 ... older than the minimum required version`.
`cloud-init.yaml` installs `openjdk-21-jre-headless` and runs
`update-alternatives --set java` before starting Jenkins.

If the service still fails after installing Java 21, clear the failure counter
first — systemd rate-limits repeated failed restarts:

```bash
sudo systemctl reset-failed jenkins
```

### 10. Node.js is required on the Jenkins agent

The pipelines run `npm ci` and `npm test` directly on the agent (`agent any`,
no container), so without Node the Install & Test stage fails with
`npm: not found` (exit code 127). `cloud-init.yaml` installs Node 20 via
NodeSource. For an existing VM:

```bash
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo bash -
sudo apt-get install -y nodejs
```

### 11. GitHub Branch Source plugin requires "Username with password"

Multibranch Pipeline jobs reject "Secret text" credentials for repository
access, even when the token is identical. Create a separate credential with the
GitHub username and a personal access token carrying the `repo` scope.

A `404 Not Found` when validating against a private repository is almost always
a token scope problem rather than a Jenkins issue. Isolate it with:

```bash
curl -H "Authorization: token $PAT" https://api.github.com/repos/<owner>/<repo>
```
