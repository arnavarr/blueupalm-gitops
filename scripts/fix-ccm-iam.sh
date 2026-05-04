#!/usr/bin/env bash
# scripts/fix-ccm-iam.sh
# BlueUPALM — Añadir roles GCP necesarios para el Cloud Controller Manager
#
# CONTEXTO:
# La SA bc-workload-nodes fue creada por Terraform con permisos mínimos de nodo
# (logging, monitoring, registry). El GCP CCM usa las credenciales del metadata
# server del nodo (la misma SA), pero necesita permisos adicionales para:
#   1. Listar nodos/instancias GCE → roles/compute.viewer
#   2. Gestionar Load Balancers → roles/compute.loadBalancerAdmin
#
# Este script añade los roles necesarios de forma idempotente.
# Ejecutar UNA VEZ tras el bootstrap del cluster.
# Los cambios serán recogidos por Terraform en el próximo `terraform apply`.
#
# USO: bash scripts/fix-ccm-iam.sh

set -euo pipefail

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
NODES_SA="bc-workload-nodes@${GCP_PROJECT_ID}.iam.gserviceaccount.com"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }

echo -e "\n${BLUE}══ BlueUPALM — Fix IAM para GCP CCM ══${NC}\n"
info "Service Account: ${NODES_SA}"
info "Proyecto: ${GCP_PROJECT_ID}"
echo ""

# ── Roles requeridos por el GCP Cloud Controller Manager ─────────────────────
# roles/compute.viewer         → listar instancias, zonas, regiones
# roles/compute.loadBalancerAdmin → crear/actualizar/borrar LBs para type=LoadBalancer
ROLES=(
  "roles/compute.viewer"
  "roles/compute.loadBalancerAdmin"
)

for ROLE in "${ROLES[@]}"; do
  info "Añadiendo rol: ${ROLE}"
  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${NODES_SA}" \
    --role="${ROLE}" \
    --condition=None \
    --quiet 2>/dev/null && \
    success "  ${ROLE} → OK" || \
    warn "  ${ROLE} → ya existía o error (continúa)"
done

echo ""
success "Roles IAM actualizados para el CCM ✅"
echo ""
warn "IMPORTANTE: Estos roles no están gestionados por Terraform todavía."
warn "Añadir a terraform/modules/iam/main.tf para hacer el cambio persistente:"
echo ""
cat << 'EOF'
  # ── Roles adicionales para GCP CCM ──────────────────────────────────────────
  resource "google_project_iam_member" "nodes_compute_viewer" {
    project = var.project_id
    role    = "roles/compute.viewer"
    member  = "serviceAccount:${google_service_account.nodes.email}"
  }

  resource "google_project_iam_member" "nodes_lb_admin" {
    project = var.project_id
    role    = "roles/compute.loadBalancerAdmin"
    member  = "serviceAccount:${google_service_account.nodes.email}"
  }
EOF
echo ""
