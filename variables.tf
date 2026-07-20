variable "location" {
  description = "Región de Azure donde se crean todos los recursos"
  type        = string
  default     = "eastus2"
}

variable "resource_group_name" {
  description = "Nombre del resource group"
  type        = string
  default     = "rg-devops-lab"
}

variable "name_prefix" {
  description = "Prefijo corto usado para generar nombres únicos (ACR, DNS de la VM, etc.). El nombre del ACR (name_prefix + 'acr') debe ser único a nivel global en Azure."
  type        = string
  default     = "devopslab01"
}

variable "my_ip" {
  description = "Tu IP pública (sin /32) permitida para SSH y Jenkins. Ej: 203.0.113.10"
  type        = string
}

variable "github_webhook_cidrs" {
  description = "Rangos CIDR de los webhooks de GitHub (ver https://api.github.com/meta -> hooks). Solo se usan los IPv4 para la NSG."
  type        = list(string)
  default = [
    "192.30.252.0/22",
    "185.199.108.0/22",
    "140.82.112.0/20",
    "143.55.64.0/20",
  ]
}

variable "vm_admin_username" {
  description = "Usuario administrador de la VM de Jenkins"
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key_path" {
  description = "Ruta local a la clave pública SSH para la VM de Jenkins (debe ser RSA; Azure no acepta ed25519 en admin_ssh_key)"
  type        = string
  default     = "~/.ssh/devops_lab_rsa.pub"
}

variable "aks_node_count" {
  description = "Número de nodos del pool por defecto de AKS"
  type        = number
  default     = 1
}

variable "aks_node_vm_size" {
  description = "Tamaño de VM para los nodos de AKS. Standard_B2s no está disponible: la familia Standard BS está bloqueada para esta suscripción en eastus2 (NotAvailableForSubscription). Standard_D2s_v3 es el reemplazo más chico/económico sin esa restricción."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "jenkins_vm_size" {
  description = "Tamaño de VM para el servidor Jenkins. Ver nota en aks_node_vm_size sobre por qué no se usa Standard_B2s."
  type        = string
  default     = "Standard_D2s_v3"
}

variable "kubernetes_version" {
  description = "Versión de Kubernetes para AKS. Vacío = la default que ofrece el provider/región."
  type        = string
  default     = null
}
