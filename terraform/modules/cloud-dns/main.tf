# terraform/modules/cloud-dns/main.tf
# BlueUPALM — Módulo Cloud DNS
#
# Estado verificado (2026-04-24):
#   ✅ navarro-bores.com ya tiene NS delegados a ns-cloud-e{1-4}.googledomains.com en eNom
#   ⚠️  La zona Cloud DNS no existe aún en el proyecto GCP — este módulo la crea
#   → No se requiere ninguna acción manual en el registrador eNom

variable "project_id"   { type = string }
variable "domain_name"  { type = string }
variable "ingress_ip"   { type = string }

resource "google_dns_managed_zone" "blueupalm" {
  name        = "blueupalm-zone"
  dns_name    = "${var.domain_name}."
  project     = var.project_id
  description = "Zona DNS para BlueUPALM — cert-manager DNS-01 + registros A del Ingress"

  # Logging de queries DNS para auditoría (requerido por DORA)
  cloud_logging_config {
    enable_logging = true
  }
}

# ── Registros A para los subdominios del Ingress Traefik ─────────────────────
locals {
  subdomains = ["blueupalm", "auth", "hubble", "grafana"]
}

resource "google_dns_record_set" "ingress_a_records" {
  for_each = toset(local.subdomains)

  name         = "${each.key}.${var.domain_name}."
  type         = "A"
  ttl          = 300
  managed_zone = google_dns_managed_zone.blueupalm.name
  project      = var.project_id
  rrdatas      = [var.ingress_ip]
}

output "zone_name"    { value = google_dns_managed_zone.blueupalm.name }
output "nameservers"  { value = google_dns_managed_zone.blueupalm.name_servers }
