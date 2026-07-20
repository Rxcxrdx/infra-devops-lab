output "jenkins_public_ip" {
  description = "IP pública de la VM de Jenkins (SSH y http://<ip>:8080)"
  value       = azurerm_public_ip.jenkins.ip_address
}

output "acr_login_server" {
  description = "Login server del ACR"
  value       = azurerm_container_registry.main.login_server
}

output "aks_get_credentials_command" {
  description = "Comando para obtener credenciales de kubectl del cluster AKS"
  value       = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name}"
}
