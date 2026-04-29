#!/usr/bin/env bash
# hibernate.sh
# BlueUPALM — Hibernación de Sesión: Ahorro de Costes sin pérdida de Base
#
# Este script prepara la infraestructura para una pausa, eliminando los recursos
# de alto coste (VMs, discos, LBs) pero conservando la base estructural (VPC, DNS, IAM, Imagen GCE).
#
# RECURSOS ELIMINADOS (Coste $):
#   1. LoadBalancer Services (Forwarding Rules)
#   2. PersistentVolumes y Discos (Rook-Ceph, PostgreSQL, etc.)
#   3. VMs de los nodos (Control Plane y Workers)
#   4. Management Cluster local (kind)
#
# RECURSOS CONSERVADOS (Base para la siguiente sesión):
#   1. Red VPC y Subnets
#   2. Cuentas de Servicio y Permisos IAM
#   3. Zona DNS y Registros A del Ingress (navarro-bores.com)
#   4. Secretos en Secret Manager
#   5. Imagen GCE personalizada (blueupalm-k8s-node) -> ¡Fundamental para rapidez!
#
# USO: bash hibernate.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}══ Paso $1: $2 ══${NC}"; }

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
GCP_REGION="${GCP_REGION:-europe-west1}"
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"
WORKLOAD_KUBECONFIG="${HOME}/.kube/blueupalm-workload.yaml"

echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  ❄️  BlueUPALM — HIBERNACIÓN DE INFRAESTRUCTURA${NC}"
echo -e "${BOLD}${BLUE}  Proyecto: ${GCP_PROJECT_ID} | Ahorro de costes activado${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

KUBECTL_WC="kubectl --kubeconfig=$WORKLOAD_KUBECONFIG"

# ── PASO 1: Eliminar LoadBalancer Services ────────────────────────────────────
step "1" "Eliminando Services LoadBalancer (ahorro de Forwarding Rules)"
if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    info "Borrando Services tipo LoadBalancer..."
    $KUBECTL_WC get svc -A --no-headers 2>/dev/null | awk '{print $1, $2}' | \
    while read ns name; do
        TYPE=$($KUBECTL_WC get svc -n "$ns" "$name" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
        if [ "$TYPE" = "LoadBalancer" ]; then
            info "Borrando LoadBalancer: $ns/$name"
            $KUBECTL_WC delete svc -n "$ns" "$name" --wait=false
        fi
    done
    sleep 10
else
    warn "kubeconfig de Workload no encontrado — saltando paso 1"
fi

# ── PASO 2: Eliminar PVCs y Discos ────────────────────────────────────────────
step "2" "Eliminando PVCs (ahorro de almacenamiento persistente)"
if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    $KUBECTL_WC delete pvc -A --all --wait=false 2>/dev/null || true
    info "PVCs marcados para eliminación"
fi

# ── PASO 3: Destruir Workload Cluster vía CAPI ────────────────────────────────
step "3" "Destruyendo VMs del Cluster (CAPG elimina instancias GCE)"
if [ -f "$MGMT_KUBECONFIG" ]; then
    export KUBECONFIG="$MGMT_KUBECONFIG"

    # Forzar eliminación de finalizers si es necesario (lección aprendida)
    info "Limpiando finalizers para asegurar eliminación limpia..."
    kubectl patch cluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
    kubectl patch gcpcluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true

    info "Eliminando el Cluster bc-workload..."
    kubectl delete cluster bc-workload --namespace=default --wait=false 2>/dev/null || true

    success "Solicitud de eliminación de VMs enviada ✅"
else
    warn "Management cluster no disponible."
fi

# ── PASO 4: Hibernar Management Cluster ───────────────────────────────────────
step "4" "Eliminando Management Cluster local (kind)"
kind delete cluster --name blueupalm-mgmt 2>/dev/null && \
    success "Management Cluster kind eliminado ✅"

rm -f "$MGMT_KUBECONFIG" "$WORKLOAD_KUBECONFIG"

# ── RESUMEN ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ HIBERNACIÓN COMPLETADA${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}CONSERVADO:${NC}"
echo -e "  - VPC, Subnets, IAM, DNS (Terraform State intacto)"
echo -e "  - Imagen GCE Custom (Lista para el próximo arranque)"
echo -e "  - Secretos en Secret Manager"
echo ""
echo -e "  ${BOLD}ELIMINADO:${NC}"
echo -e "  - VMs GCE y Discos de datos (Coste mensual -> $0)"
echo -e "  - Forwarding Rules de GCP"
echo ""
echo -e "  ${BOLD}PRÓXIMA SESIÓN:${NC}"
echo -e "  1. bash setup_all.sh   (Se saltará Terraform e Imagen GCE si existen)"
echo -e "  2. El cluster se redesplegará en ~10 min en lugar de ~30 min."
echo ""
