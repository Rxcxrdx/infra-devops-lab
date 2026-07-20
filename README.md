# infra-devops-lab

Infraestructura mínima en Azure (Terraform) para un laboratorio de DevOps:
Resource Group, VNet con 2 subnets, ACR (Basic), AKS (1 nodo Standard_B2s) y
una VM de Jenkins (Ubuntu 22.04, Standard_B2s) con Docker, Java 17, Azure CLI
y kubectl preinstalados vía cloud-init.

Todo está dimensionado al mínimo (sin zonas de disponibilidad, sin Log
Analytics) para minimizar costos. **Esto sigue generando cargos mientras
los recursos existan.**

## Requisitos

- Terraform >= 1.7
- Azure CLI autenticado (`az login`) con una suscripción activa
- Una clave pública SSH (por defecto `~/.ssh/id_ed25519.pub`)
- Tu IP pública actual (`curl ifconfig.me`)

## Uso

```bash
cp terraform.tfvars.example terraform.tfvars
# editar terraform.tfvars: al menos my_ip

terraform init
terraform plan        # revisa QUÉ se va a crear antes de aplicar
terraform apply        # ~10-15 min
```

Al finalizar, Terraform imprime:
- IP pública de la VM de Jenkins
- Login server del ACR
- El comando `az aks get-credentials ...` para configurar kubectl

Verifica el cluster:

```bash
az aks get-credentials --resource-group rg-devops-lab --name aks-devops-lab
kubectl get nodes     # debe mostrar 1 nodo Ready
```

Jenkins queda disponible en `http://<ip-publica>:8080` (solo accesible desde
tu IP y desde los rangos de webhooks de GitHub). La contraseña inicial de
Jenkins se obtiene por SSH:

```bash
ssh azureuser@<ip-publica> sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

## Notas de seguridad / costos

- El NSG de la VM de Jenkins solo permite 22 y 8080 desde `var.my_ip` y 8080
  desde los rangos de webhook de GitHub (`var.github_webhook_cidrs`, ver
  https://api.github.com/meta). Si tu IP cambia, actualiza `terraform.tfvars`
  y vuelve a aplicar.
- El ACR tiene el usuario admin habilitado (necesario para simplificar el
  login desde Jenkins/docker); considera deshabilitarlo y usar un service
  principal o `az acr login` con AAD si esto pasa de ser un laboratorio.
- AKS usa 1 solo nodo `Standard_B2s`: sin alta disponibilidad, solo para
  pruebas.

## Destruir todo al final de la sesión

```bash
terraform destroy
```

Si vas a continuar al día siguiente y quieres evitar el costo de AKS durante
la noche sin perder la configuración, puedes pausar el cluster en lugar de
destruirlo (la VM de Jenkins y el ACR igual siguen facturando):

```bash
az aks stop --name aks-devops-lab --resource-group rg-devops-lab
# al retomar:
az aks start --name aks-devops-lab --resource-group rg-devops-lab
```
