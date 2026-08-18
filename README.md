# infra-devops-lab

<p>
  <img src="https://img.shields.io/badge/Terraform-7B42BC?style=flat-square&logo=terraform&logoColor=white" alt="Terraform"/>
  <img src="https://img.shields.io/badge/Microsoft_Azure-0078D4?style=flat-square&logo=microsoftazure&logoColor=white" alt="Azure"/>
  <img src="https://img.shields.io/badge/Kubernetes-326CE5?style=flat-square&logo=kubernetes&logoColor=white" alt="Kubernetes"/>
  <img src="https://img.shields.io/badge/Jenkins-D24939?style=flat-square&logo=jenkins&logoColor=white" alt="Jenkins"/>
</p>

Azure infrastructure and Kubernetes manifests for the DevOps lab: resource
group, virtual network with two subnets, container registry, AKS cluster, and a
Jenkins VM provisioned through cloud-init.

> Part of the [**Micro-Frontends on Azure AKS**](https://github.com/Rxcxrdx/microfrontends-aks-jenkins)
> project — see that repository for the full architecture overview.

## What gets provisioned

| Resource | Notes |
|:--|:--|
| Resource Group | Single group holding every resource, in `eastus2` |
| Virtual Network | `10.0.0.0/16`, with dedicated subnets for AKS and Jenkins |
| Container Registry | Basic tier, admin user enabled for simplicity |
| AKS cluster | Single node, `AcrPull` role assigned via Managed Identity |
| Jenkins VM | Ubuntu 22.04 with Docker, Java 21, Node 20, kubectl, and Azure CLI |
| Network Security Group | SSH and port 8080 restricted to one IP plus GitHub webhook ranges |

Everything is sized to the minimum — no availability zones, no Log Analytics —
to keep lab costs down. **Resources are billable while they exist.**

## Requirements

- Terraform >= 1.7
- Azure CLI authenticated (`az login`) with an active subscription
- An **RSA** SSH public key — Azure rejects ed25519 for Linux VMs
- Your current public IP (`curl ifconfig.me`)

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars
# set at least my_ip

terraform init
terraform plan     # review what will be created
terraform apply    # roughly 10-15 minutes
```

Terraform outputs the Jenkins VM public IP, the registry login server, and the
`az aks get-credentials` command for configuring kubectl.

Verify the cluster:

```bash
az aks get-credentials --resource-group <resource-group> --name <cluster-name>
kubectl get nodes
```

## Deploying the applications

The `k8s/` directory holds the manifests for the four applications:

```bash
kubectl apply -f k8s/api-node/
kubectl apply -f k8s/mfe-consultas/
kubectl apply -f k8s/mfe-reportes/
kubectl apply -f k8s/shell-app/
kubectl apply -f k8s/ingress.yaml
```

Ingress routing is split across two resources. `/api`, `/consultas`, and
`/reportes` use `rewrite-target` because those backends do not know their path
prefix; `/` routes to the host application **without** rewriting, because
Next.js needs the full path to serve its assets under `/_next/`.

## Jenkins

Jenkins is available at `http://<vm-public-ip>:8080`, reachable only from the
configured IP and from GitHub's webhook ranges. The initial admin password:

```bash
ssh azureuser@<vm-public-ip> sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Each application repository defines its own Multibranch Pipeline job. Note that
the GitHub Branch Source plugin only accepts "Username with password"
credentials for repository access, even when the password is a personal access
token.

## Security and cost notes

- The network security group restricts SSH and 8080 to `var.my_ip` and
  `var.github_webhook_cidrs` (see https://api.github.com/meta). Update
  `terraform.tfvars` and re-apply when your IP changes.
- The registry admin user is enabled to simplify Docker login from Jenkins.
  Beyond a lab, prefer a Service Principal or `az acr login` with Entra ID.
- AKS runs a single node: no high availability.
- `terraform.tfstate`, `terraform.tfvars`, and kubeconfig files are excluded via
  `.gitignore` and must never be committed — state files contain secrets.

## Tearing down

```bash
terraform destroy
```

To pause overnight without losing configuration (the VM and registry still
incur charges):

```bash
az aks stop  --name <cluster-name> --resource-group <resource-group>
az aks start --name <cluster-name> --resource-group <resource-group>
```
