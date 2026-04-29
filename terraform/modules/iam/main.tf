# terraform/modules/iam/main.tf
# BlueUPALM — Módulo IAM
# Service Accounts con permisos mínimos (Principle of Least Privilege)
# Workload Identity para eliminar credenciales estáticas en pods

variable "project_id"    { type = string }
variable "cluster_name"  { type = string }

# ── Service Account: Cluster API Provider GCP (CAPG) ─────────────────────────
# Necesita permisos para crear/destruir VMs, discos, IPs y reglas de firewall
resource "google_service_account" "capg" {
  account_id   = "${var.cluster_name}-capg"
  display_name = "BlueUPALM — Cluster API Provider GCP Controller"
  project      = var.project_id
  description  = "SA usada por CAPG para aprovisionar el Workload Cluster sobre GCE"
}

resource "google_project_iam_member" "capg_compute_admin" {
  project = var.project_id
  role    = "roles/compute.admin"
  member  = "serviceAccount:${google_service_account.capg.email}"
}

resource "google_project_iam_member" "capg_iam_user" {
  project = var.project_id
  role    = "roles/iam.serviceAccountUser"
  member  = "serviceAccount:${google_service_account.capg.email}"
}

resource "google_project_iam_member" "capg_storage" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.capg.email}"
}

# ── Service Account: Nodos del Workload Cluster ───────────────────────────────
# Los nodos GCE necesitan permisos para Cloud Logging, Monitoring y pull de imágenes
resource "google_service_account" "nodes" {
  account_id   = "${var.cluster_name}-nodes"
  display_name = "BlueUPALM — Nodos GCE del Workload Cluster"
  project      = var.project_id
  description  = "SA mínima para nodos GCE: logging, monitoring, container registry"
}

resource "google_project_iam_member" "nodes_logging" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_monitoring" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_registry" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_project_iam_member" "nodes_artifact_registry" {
  project = var.project_id
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

# ── Service Account: External Secrets Operator ────────────────────────────────
# Acceso de solo lectura a GCP Secret Manager desde pods via Workload Identity
resource "google_service_account" "external_secrets" {
  account_id   = "${var.cluster_name}-ext-secrets"
  display_name = "BlueUPALM — External Secrets Operator"
  project      = var.project_id
  description  = "SA para ESO: acceso de lectura a Secret Manager via Workload Identity"
}

resource "google_project_iam_member" "external_secrets_sm_reader" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.external_secrets.email}"
}

# ── Workload Identity Binding (ESO → SA GCP) ──────────────────────────────────
# Permite que el ServiceAccount de K8s `external-secrets/external-secrets`
# impersona la SA de GCP sin credenciales estáticas (keyless auth)
# NOTA: Deshabilitado temporalmente hasta que el pool .svc.id.goog esté disponible o se use Federation.
# resource "google_service_account_iam_member" "external_secrets_wi" {
#   service_account_id = google_service_account.external_secrets.name
#   role               = "roles/iam.workloadIdentityUser"
#   member             = "serviceAccount:${var.project_id}.svc.id.goog[external-secrets/external-secrets]"
# }

# ── Service Account: cert-manager (DNS-01 solver para Cloud DNS) ───────────────
resource "google_service_account" "cert_manager" {
  account_id   = "${var.cluster_name}-cert-manager"
  display_name = "BlueUPALM — cert-manager DNS-01 Solver"
  project      = var.project_id
  description  = "SA para cert-manager: gestión de registros TXT en Cloud DNS para Let's Encrypt"
}

resource "google_project_iam_member" "cert_manager_dns_admin" {
  project = var.project_id
  role    = "roles/dns.admin"
  member  = "serviceAccount:${google_service_account.cert_manager.email}"
}

# resource "google_service_account_iam_member" "cert_manager_wi" {
#   service_account_id = google_service_account.cert_manager.name
#   role               = "roles/iam.workloadIdentityUser"
#   member             = "serviceAccount:${var.project_id}.svc.id.goog[cert-manager/cert-manager]"
# }

# ── Clave JSON para CAPG (clusterctl necesita credenciales en bootstrap) ───────
resource "google_service_account_key" "capg_key" {
  service_account_id = google_service_account.capg.name
}

output "capg_sa_email"             { value = google_service_account.capg.email }
output "nodes_sa_email"            { value = google_service_account.nodes.email }
output "external_secrets_sa_email" { value = google_service_account.external_secrets.email }
output "cert_manager_sa_email"     { value = google_service_account.cert_manager.email }
output "capg_key_b64"              {
  value     = google_service_account_key.capg_key.private_key
  sensitive = true
}
