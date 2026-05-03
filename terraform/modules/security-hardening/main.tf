# terraform/modules/security-hardening/main.tf
# BlueUPALM — Fase 4: Zero-Trust Control Plane
#
# Recursos:
#   1. KMS KeyRing + CryptoKey para cifrado de identidades Ziti en MachineConfig
#   2. GCS bucket para DR (etcd snapshots + Talos secrets + SPIRE CA)
#   3. Firewall: deniega acceso directo a Talos API (50000) y kube-apiserver (6443)
#      IMPORTANTE: aplicar SOLO después de verificar acceso vía Ziti overlay
#
# Arquitectura: docs/architecture/talos-sovereign-stack.md (Sección 5)

variable "project_id"   { type = string }
variable "region"       { type = string }
variable "cluster_name" { type = string }
variable "vpc_name"     { type = string }

# ── KMS KeyRing para cifrado de secretos del cluster ─────────────────────────
resource "google_kms_key_ring" "blueupalm" {
  name     = "blueupalm"
  location = "global"
  project  = var.project_id
}

# CryptoKey para identidades Ziti en MachineConfig
resource "google_kms_crypto_key" "ziti_identity" {
  name            = "ziti-machineconfig-identity"
  key_ring        = google_kms_key_ring.blueupalm.id
  rotation_period = "7776000s"  # 90 días

  lifecycle {
    prevent_destroy = true
  }
}

# CryptoKey para DR (etcd snapshots + Talos PKI secrets)
resource "google_kms_crypto_key" "dr_backup" {
  name            = "dr-backup"
  key_ring        = google_kms_key_ring.blueupalm.id
  rotation_period = "7776000s"  # 90 días

  lifecycle {
    prevent_destroy = true
  }
}

# ── GCS Bucket para DR ────────────────────────────────────────────────────────
resource "google_storage_bucket" "dr" {
  name                        = "${var.project_id}-blueupalm-dr"
  location                    = var.region
  project                     = var.project_id
  force_destroy               = false
  uniform_bucket_level_access = true

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition { age = 30 }
    action    { type = "Delete" }
  }

  # Cifrado con CMEK (Customer Managed Encryption Key)
  encryption {
    default_kms_key_name = google_kms_crypto_key.dr_backup.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Estructura de carpetas en GCS (objetos vacíos como marcadores)
resource "google_storage_bucket_object" "dr_structure" {
  for_each = toset(["etcd/", "talos-secrets/", "spire/"])
  name     = each.key
  bucket   = google_storage_bucket.dr.name
  content  = ""
}

# ── Service Account para el Job de backup de etcd ────────────────────────────
resource "google_service_account" "etcd_backup" {
  account_id   = "blueupalm-etcd-backup"
  display_name = "BlueUPALM etcd Backup Job"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "etcd_backup_writer" {
  bucket = google_storage_bucket.dr.name
  role   = "roles/storage.objectCreator"
  member = "serviceAccount:${google_service_account.etcd_backup.email}"
}

# ── Permiso para que los nodos usen KMS (cifrar/descifrar Ziti identity) ──────
resource "google_kms_crypto_key_iam_member" "nodes_ziti_decrypt" {
  crypto_key_id = google_kms_crypto_key.ziti_identity.id
  role          = "roles/cloudkms.cryptoKeyDecrypter"
  # La SA de los nodos (del módulo IAM) puede descifrar la identidad Ziti al boot
  member        = "serviceAccount:${var.nodes_sa_email}"
}

# ── FIREWALL: bloquear acceso directo al plano de control ─────────────────────
# ⚠️  ACTIVAR SOLO en Fase 4 — DESPUÉS de verificar acceso vía Ziti overlay
# Procedimiento: scripts/fase4-enable-zero-trust-firewall.sh

# Regla de denegación: nadie accede directamente a Talos API ni kube-apiserver
resource "google_compute_firewall" "deny_controlplane_direct" {
  name      = "${var.cluster_name}-deny-cp-direct"
  network   = var.vpc_name
  project   = var.project_id
  direction = "INGRESS"
  priority  = 800   # Mayor prioridad que allow-internal (1000)

  deny {
    protocol = "tcp"
    ports    = ["50000", "6443"]
  }

  # Bloquea TODO el tráfico externo — excepto el pod CIDR (Ziti Router interno)
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-node"]

  # Esta regla se crea DESACTIVADA (disabled=true) y se activa manualmente
  # tras verificar el acceso Ziti: scripts/fase4-enable-zero-trust-firewall.sh
  disabled = true

  description = "FASE 4: Bloquea acceso directo a Talos API y kube-apiserver. Activar SOLO tras verificar acceso Ziti."
}

# Regla de permiso: solo el pod CIDR interno puede acceder (Ziti Router en cluster)
resource "google_compute_firewall" "allow_controlplane_from_pods" {
  name      = "${var.cluster_name}-allow-cp-from-pods"
  network   = var.vpc_name
  project   = var.project_id
  direction = "INGRESS"
  priority  = 700   # Mayor prioridad que deny (800)

  allow {
    protocol = "tcp"
    ports    = ["50000", "6443"]
  }

  # Solo pods internos del cluster (Ziti Router pod)
  source_ranges = ["10.1.0.0/16"]
  target_tags   = ["${var.cluster_name}-node"]
}

# ── Outputs ───────────────────────────────────────────────────────────────────
output "kms_key_ring_id"        { value = google_kms_key_ring.blueupalm.id }
output "kms_ziti_key_id"        { value = google_kms_crypto_key.ziti_identity.id }
output "kms_dr_key_id"          { value = google_kms_crypto_key.dr_backup.id }
output "dr_bucket_name"         { value = google_storage_bucket.dr.name }
output "etcd_backup_sa_email"   { value = google_service_account.etcd_backup.email }
output "deny_firewall_name"     { value = google_compute_firewall.deny_controlplane_direct.name }
