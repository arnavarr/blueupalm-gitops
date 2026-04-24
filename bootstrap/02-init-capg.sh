#!/usr/bin/env bash
# bootstrap/02-init-capg.sh
# BlueUPALM — Inicialización de Cluster API Provider GCP (CAPG)
#
# Instala los controladores de Cluster API en el Management Cluster local (kind)
# apuntando a GCP como proveedor de infraestructura.
#
# PREREQUISITOS:
#   - bash bootstrap/01-install-local-deps.sh completado
#   - terraform apply completado (genera bootstrap/capg-credentials.json)
#   - Variables de entorno definidas (ver terraform.tfvars)
#
# USO: bash bootstrap/02-init-capg.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  BlueUPALM — Inicialización Cluster API Provider GCP"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Variables requeridas ──────────────────────────────────────────────────────
: "${GCP_PROJECT_ID:?Falta GCP_PROJECT_ID}"
: "${GCP_REGION:?Falta GCP_REGION}"

MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"
CAPG_CREDENTIALS="${BASH_SOURCE%/*}/capg-credentials.json"

# ── Verificar kubeconfig del Management Cluster ───────────────────────────────
[ -f "$MGMT_KUBECONFIG" ] || error "kubeconfig no encontrado: $MGMT_KUBECONFIG. Ejecutar 01-install-local-deps.sh"
export KUBECONFIG="$MGMT_KUBECONFIG"

# ── Verificar credenciales CAPG generadas por Terraform ──────────────────────
[ -f "$CAPG_CREDENTIALS" ] || error "capg-credentials.json no encontrado. Ejecutar terraform apply primero."
export GOOGLE_APPLICATION_CREDENTIALS="$CAPG_CREDENTIALS"

# ── Variables CAPG requeridas ─────────────────────────────────────────────────
export GCP_PROJECT_ID
export GCP_REGION
export EXP_MACHINE_POOL=false                    # No usar Machine Pools (usar MachineDeployment)
export CLUSTER_TOPOLOGY=false                     # Topology API opcional

info "GCP Project: $GCP_PROJECT_ID"
info "GCP Region:  $GCP_REGION"
info "CAPG credentials: $CAPG_CREDENTIALS"

# ── Inicializar Cluster API con proveedor GCP ─────────────────────────────────
info "Inicializando clusterctl con proveedor GCP..."
clusterctl init \
    --infrastructure gcp:v1.7.0 \
    --core cluster-api:v1.7.0 \
    --bootstrap kubeadm:v1.7.0 \
    --control-plane kubeadm:v1.7.0

# ── Esperar a que los controladores estén Ready ───────────────────────────────
info "Esperando controladores CAPI/CAPG (hasta 5 min)..."

kubectl wait deployment \
    --all \
    --for=condition=Available \
    --timeout=300s \
    -n capi-system

kubectl wait deployment \
    --all \
    --for=condition=Available \
    --timeout=300s \
    -n capg-system

success "Controladores CAPI/CAPG operativos"

# ── Verificar CRDs instalados ─────────────────────────────────────────────────
info "Verificando CRDs instalados..."
for crd in clusters.cluster.x-k8s.io machines.cluster.x-k8s.io gcpclusters.infrastructure.cluster.x-k8s.io; do
    kubectl get crd "$crd" &>/dev/null && success "CRD: $crd" || error "CRD no encontrado: $crd"
done

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Cluster API Provider GCP listo"
echo ""
echo "  Próximo paso: kubectl apply -f cluster-api/"
echo "  O ejecutar:   ./setup_all.sh"
echo "═══════════════════════════════════════════════════════"
echo ""
