# terraform/modules/secret-manager/main.tf
# BlueUPALM — Módulo GCP Secret Manager
#
# CRÍTICO DE SEGURIDAD:
#   - biscuit-root-key-pkcs8: raíz de confianza del sistema de autorización.
#     Rotación programada cada 90 días con grace period de 7 días.
#   - Los NKey seeds de NATS se auto-generan aquí como placeholder.
#     En producción, generarlos con: nsc generate nkey -u
#   - NUNCA loguear estos valores. Terraform los marca como sensitive.

variable "project_id" {
  type = string
}

variable "keycloak_admin_pass" {
  type      = string
  sensitive = true
}

variable "postgres_pass" {
  type      = string
  sensitive = true
}

variable "qdrant_api_key" {
  type      = string
  sensitive = true
}

# ── Helper: generación de valores random para demo ────────────────────────────
resource "random_password" "spire_join_token" {
  length  = 32
  special = false
}

resource "random_password" "openziti_enrollment_jwt" {
  length  = 64
  special = false
}

# ── Secretos BlueUPALM ────────────────────────────────────────────────────────
locals {
  secrets = {
    "blueupalm/keycloak-admin-password" = {
      value       = var.keycloak_admin_pass
      description = "Password admin Keycloak — Realm blueupalm"
      labels      = { component = "identity", rotation = "manual" }
    }
    "blueupalm/nats-nkey-seed-edge" = {
      # Placeholder: generar con 'nsc generate nkey -u' y sustituir antes de producción
      value       = "SUAXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
      description = "NKey Ed25519 seed para edge-security (Rust/Axum) — autenticación NATS"
      labels      = { component = "messaging", rotation = "90d" }
    }
    "blueupalm/nats-nkey-seed-ingestor" = {
      value       = "SUAYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYYY"
      description = "NKey Ed25519 seed para ingestion-agent (Python) — autenticación NATS"
      labels      = { component = "messaging", rotation = "90d" }
    }
    "blueupalm/biscuit-root-key-pkcs8" = {
      # Placeholder: generar con 'biscuit keypair' y sustituir antes de producción
      # CRÍTICO: Rotar cada 90 días. Ver grace period en external-secrets manifest.
      value       = "PLACEHOLDER_BISCUIT_ROOT_KEY_PKCS8_REPLACE_BEFORE_PROD"
      description = "Clave raíz PKCS#8 para firma de tokens Biscuit — ROTAR CADA 90 DÍAS"
      labels      = { component = "authorization", rotation = "90d", criticality = "critical" }
    }
    "blueupalm/postgres-password" = {
      value       = var.postgres_pass
      description = "Password PostgreSQL para base de datos relacional de aplicación"
      labels      = { component = "data", rotation = "manual" }
    }
    "blueupalm/qdrant-api-key" = {
      value       = var.qdrant_api_key
      description = "API Key para Qdrant vector database (memoria de sesión IA)"
      labels      = { component = "data", rotation = "manual" }
    }
    "blueupalm/openziti-enrollment-jwt" = {
      value       = random_password.openziti_enrollment_jwt.result
      description = "JWT de enrolamiento para OpenZiti edge routers"
      labels      = { component = "networking", rotation = "on-deploy" }
    }
    "blueupalm/spire-join-token" = {
      value       = random_password.spire_join_token.result
      description = "Token de join para SPIRE agents — rotación automática en cada deploy"
      labels      = { component = "security", rotation = "on-deploy" }
    }
  }
}

resource "google_secret_manager_secret" "secrets" {
  for_each  = local.secrets
  project   = var.project_id
  secret_id = replace(each.key, "/", "-")

  labels = each.value.labels

  replication {
    # Replicación automática en la región EU para soberanía de datos GDPR
    user_managed {
      replicas {
        location = "europe-west1"
      }
      replicas {
        location = "europe-west3"
      }
    }
  }
}

resource "google_secret_manager_secret_version" "secrets" {
  for_each    = local.secrets
  secret      = google_secret_manager_secret.secrets[each.key].id
  secret_data = each.value.value
}

output "secret_ids" {
  value = { for k, v in google_secret_manager_secret.secrets : k => v.secret_id }
}
