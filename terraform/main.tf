# terraform/main.tf
# BlueUPALM Platform — Infraestructura Base GCP
#
# PREREQUISITOS:
#   gcloud auth application-default login
#   gcloud config set project <GCP_PROJECT_ID>
#
# USO:
#   cp terraform.tfvars.example terraform.tfvars
#   # Editar terraform.tfvars
#   terraform init
#   terraform plan
#   terraform apply

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Descomentar para usar GCS como backend remoto (recomendado para equipo)
  # backend "gcs" {
  #   bucket = "<GCP_PROJECT_ID>-tfstate"
  #   prefix = "blueupalm/terraform.tfstate"
  # }
}

provider "google" {
  project = var.gcp_project_id
  region  = var.gcp_region
  zone    = var.gcp_zone
}

# ── IP Estática para el Ingress Traefik ───────────────────────────────────────
# Reservar antes que los módulos para poder usarla en DNS y outputs
resource "google_compute_global_address" "ingress_ip" {
  name        = "blueupalm-ingress-ip"
  project     = var.gcp_project_id
  description = "IP estática para el LoadBalancer de Traefik (Ingress BlueUPALM)"
}

# ── Módulo VPC ────────────────────────────────────────────────────────────────
module "vpc" {
  source       = "./modules/vpc"
  project_id   = var.gcp_project_id
  region       = var.gcp_region
  cluster_name = var.workload_cluster_name
}

# ── Módulo IAM ────────────────────────────────────────────────────────────────
module "iam" {
  source       = "./modules/iam"
  project_id   = var.gcp_project_id
  cluster_name = var.workload_cluster_name
}

# ── Módulo Secret Manager ─────────────────────────────────────────────────────
module "secret_manager" {
  source              = "./modules/secret-manager"
  project_id          = var.gcp_project_id
  keycloak_admin_pass = var.demo_keycloak_admin_pass
  postgres_pass       = var.demo_postgres_pass
  qdrant_api_key      = var.demo_qdrant_api_key
}

# ── Módulo Cloud DNS ──────────────────────────────────────────────────────────
# Crea la zona navarro-bores.com en GCP Cloud DNS.
# Los NS ya están delegados desde eNom — ninguna acción manual necesaria.
module "cloud_dns" {
  source      = "./modules/cloud-dns"
  project_id  = var.gcp_project_id
  domain_name = var.domain_name
  ingress_ip  = google_compute_global_address.ingress_ip.address
}

# ── Habilitar APIs de GCP requeridas ─────────────────────────────────────────
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "iam.googleapis.com",
    "secretmanager.googleapis.com",
    "dns.googleapis.com",
    "container.googleapis.com",    # Solo para imágenes, no para GKE
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
  ])

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}

# ── Guardar credenciales CAPG para bootstrap ──────────────────────────────────
# El archivo se usa en bootstrap/02-init-capg.sh como GOOGLE_APPLICATION_CREDENTIALS
resource "local_file" "capg_credentials" {
  content         = base64decode(module.iam.capg_key_b64)
  filename        = "${path.module}/../bootstrap/capg-credentials.json"
  file_permission = "0600"

  # Asegurarse de que no se sube al repositorio Git
  lifecycle {
    ignore_changes = [content]
  }
}
