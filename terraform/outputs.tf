# terraform/outputs.tf
# BlueUPALM Platform — Outputs de Terraform
# Usados por setup_all.sh para configurar el entorno post-apply

output "capg_service_account_email" {
  description = "Service Account para Cluster API Provider GCP (CAPG)"
  value       = module.iam.capg_sa_email
}

output "nodes_service_account_email" {
  description = "Service Account para los nodos del Workload Cluster"
  value       = module.iam.nodes_sa_email
}

output "external_secrets_service_account_email" {
  description = "Service Account para External Secrets Operator (acceso a GCP Secret Manager)"
  value       = module.iam.external_secrets_sa_email
}

output "vpc_name" {
  description = "Nombre de la VPC BlueUPALM"
  value       = module.vpc.network_name
}

output "subnet_name" {
  description = "Nombre de la subnet principal en europe-west1"
  value       = module.vpc.subnet_name
}

output "cloud_dns_zone_name" {
  description = "Nombre de la zona Cloud DNS (para cert-manager DNS-01 solver)"
  value       = module.cloud_dns.zone_name
}

output "cloud_dns_nameservers" {
  description = "Nameservers de la zona Cloud DNS (deben coincidir con los de eNom)"
  value       = module.cloud_dns.nameservers
}

output "secret_manager_secrets" {
  description = "Nombres de los secretos creados en GCP Secret Manager"
  value       = module.secret_manager.secret_ids
}

output "ingress_ip_name" {
  description = "Nombre del IP estático reservado para el Ingress de Traefik"
  value       = google_compute_address.ingress_ip.name
}

output "ingress_ip_address" {
  description = "Dirección IP estática del Ingress (configurar en DNS de Traefik)"
  value       = google_compute_address.ingress_ip.address
}

output "setup_instructions" {
  description = "Instrucciones post-terraform para continuar con setup_all.sh"
  value       = <<-EOT
    ═══════════════════════════════════════════════════════
    BlueUPALM — Terraform Apply Completado
    ═══════════════════════════════════════════════════════

    1. IP del Ingress: ${google_compute_address.ingress_ip.address}
       → Añadir en GCP Cloud DNS zona ${var.domain_name}:
         blueupalm  A  ${google_compute_address.ingress_ip.address}
         auth       A  ${google_compute_address.ingress_ip.address}
         hubble     A  ${google_compute_address.ingress_ip.address}
         grafana    A  ${google_compute_address.ingress_ip.address}

    2. Nameservers Cloud DNS: ${join(", ", module.cloud_dns.nameservers)}
       → Verificar que coinciden con los de eNom (ya delegados ✅)

    3. Continuar con:  ./setup_all.sh
    ═══════════════════════════════════════════════════════
  EOT
}
