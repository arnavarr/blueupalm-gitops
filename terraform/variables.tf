# terraform/variables.tf
# BlueUPALM Platform — Variables de Infraestructura GCP
# Todas las variables pueden sobreescribirse en terraform.tfvars

variable "gcp_project_id" {
  description = "ID del proyecto GCP donde se desplegará la infraestructura BlueUPALM"
  type        = string
}

variable "gcp_region" {
  description = "Región GCP principal (preferencia europea para soberanía de datos GDPR/DORA)"
  type        = string
  default     = "europe-west1"
}

variable "gcp_zone" {
  description = "Zona GCP principal dentro de la región"
  type        = string
  default     = "europe-west1-b"
}

# ── Cluster API ────────────────────────────────────────────────────────────────

variable "workload_cluster_name" {
  description = "Nombre del Workload Cluster gestionado por Cluster API"
  type        = string
  default     = "bc-workload"
}

variable "k8s_version" {
  description = "Versión de Kubernetes para el Workload Cluster"
  type        = string
  default     = "v1.29.0"
}

variable "control_plane_machine_type" {
  description = "Tipo de máquina GCE para el Control Plane"
  type        = string
  default     = "e2-standard-4"
}

variable "worker_machine_type" {
  description = "Tipo de máquina GCE para los nodos Worker"
  type        = string
  default     = "e2-standard-4"
}

variable "worker_count" {
  description = "Número de nodos worker (mínimo 3 para NATS cluster HA conforme DORA)"
  type        = number
  default     = 3

  validation {
    condition     = var.worker_count >= 3
    error_message = "DORA compliance: se requieren mínimo 3 workers para NATS JetStream HA."
  }
}

variable "worker_zones" {
  description = "Zonas GCE para distribuir los workers (anti-affinity NATS)"
  type        = list(string)
  default     = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]
}

# ── Almacenamiento ────────────────────────────────────────────────────────────

variable "os_disk_size_gb" {
  description = "Tamaño del disco OS de los nodos (GB)"
  type        = number
  default     = 100
}

variable "ceph_disk_size_gb" {
  description = "Tamaño del disco adicional para Rook-Ceph por worker (GB)"
  type        = number
  default     = 200
}

# ── DNS / TLS ─────────────────────────────────────────────────────────────────

variable "domain_name" {
  description = "Dominio raíz. NS ya delegados a GCP Cloud DNS desde el registrador eNom."
  type        = string
  default     = "navarro-bores.com"
}

variable "letsencrypt_email" {
  description = "Email para notificaciones de Let's Encrypt (expiración de certificados)"
  type        = string
}

# ── Flux CD ───────────────────────────────────────────────────────────────────

variable "flux_github_owner" {
  description = "Owner del repositorio GitHub de Flux (usuario u organización)"
  type        = string
  default     = "arnavarr"
}

variable "flux_github_repo" {
  description = "Nombre del repositorio GitHub GitOps de Flux"
  type        = string
  default     = "blueupalm-gitops"
}

# ── Demo secrets (solo valores placeholder — reemplazar antes de producción) ──

variable "demo_keycloak_admin_pass" {
  description = "Password admin Keycloak para demo. CAMBIAR antes de producción."
  type        = string
  default     = "changeme-demo-2024"
  sensitive   = true
}

variable "demo_postgres_pass" {
  description = "Password PostgreSQL para demo. CAMBIAR antes de producción."
  type        = string
  default     = "pg-changeme-demo"
  sensitive   = true
}

variable "demo_qdrant_api_key" {
  description = "API Key Qdrant para demo. CAMBIAR antes de producción."
  type        = string
  default     = "qdrant-changeme-demo"
  sensitive   = true
}
