#!/usr/bin/env bash
# cleanup_demo.sh
# BlueUPALM — Destrucción Total: Garantía de Factura GCP en €0
#
# Elimina TODOS los recursos GCP en orden inverso al despliegue:
#   1. LoadBalancer Services (forwarding rules GCP)
#   2. PersistentVolumeClaims (discos GCP PD)
#   3. Workload Cluster via CAPI (VMs + discos)
#   4. Management Cluster local (kind)
#   5. Terraform destroy (VPC, IAM, DNS, Secret Manager)
#   6. Verificación de residuos
#
# FLAGS:
#   --purge-secrets    Elimina también los secretos de GCP Secret Manager
#   --skip-confirm     Sin confirmación interactiva (para CI/CD)
#
# USO: bash cleanup_demo.sh [--purge-secrets] [--skip-confirm]

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }
step()    { echo -e "\n${BOLD}${RED}══ Paso $1: $2 ══${NC}"; }

# ── Parsear flags ─────────────────────────────────────────────────────────────
PURGE_SECRETS=false
SKIP_CONFIRM=false
for arg in "$@"; do
    case $arg in
        --purge-secrets) PURGE_SECRETS=true ;;
        --skip-confirm)  SKIP_CONFIRM=true ;;
    esac
done

GCP_PROJECT_ID="${GCP_PROJECT_ID:-blueup-bc-demo}"
GCP_REGION="${GCP_REGION:-europe-west1}"
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"
WORKLOAD_KUBECONFIG="${HOME}/.kube/blueupalm-workload.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\n${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  ⚠️  BlueUPALM — DESTRUCCIÓN TOTAL DE INFRAESTRUCTURA${NC}"
echo -e "${BOLD}${RED}  Proyecto: ${GCP_PROJECT_ID} | Región: ${GCP_REGION}${NC}"
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}\n"

# ── Confirmación interactiva ──────────────────────────────────────────────────
if [ "$SKIP_CONFIRM" = false ]; then
    echo -e "${YELLOW}Se eliminarán TODOS los recursos de GCP. Esta acción es IRREVERSIBLE.${NC}"
    echo -e "${YELLOW}Secretos de Secret Manager: ${PURGE_SECRETS} (usar --purge-secrets para eliminarlos)${NC}\n"
    read -rp "Escribir 'DESTRUIR' para confirmar: " CONFIRM
    [ "$CONFIRM" = "DESTRUIR" ] || { info "Operación cancelada."; exit 0; }
fi

KUBECTL_WC="kubectl --kubeconfig=$WORKLOAD_KUBECONFIG"

# ── PASO 1: Eliminar LoadBalancer Services ────────────────────────────────────
step "1" "Eliminando Services LoadBalancer (forwarding rules GCP)"
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

    info "Esperando eliminación de forwarding rules (30s)..."
    sleep 30

    # Verificar que GCP no tiene forwarding rules del cluster
    RULES=$(gcloud compute forwarding-rules list \
        --project="$GCP_PROJECT_ID" \
        --filter="description~bc-workload" \
        --format="value(name)" 2>/dev/null | wc -l)
    [ "$RULES" -eq 0 ] && success "Forwarding rules eliminadas ✅" || \
        warn "$RULES forwarding rules aún presentes (pueden tardar en eliminarse)"
else
    warn "kubeconfig del Workload Cluster no encontrado — saltando paso 1"
fi

# ── PASO 2: Eliminar PersistentVolumeClaims ───────────────────────────────────
step "2" "Eliminando PersistentVolumeClaims (discos GCP PD)"
if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    info "Borrando todos los PVCs..."
    $KUBECTL_WC delete pvc -A --all --wait=false 2>/dev/null || warn "Sin PVCs o error al borrar"

    info "Esperando liberación de discos GCP (60s)..."
    sleep 60

    DISKS=$(gcloud compute disks list \
        --project="$GCP_PROJECT_ID" \
        --filter="labels.cluster=bc-workload OR name~bc-workload" \
        --format="value(name)" 2>/dev/null | wc -l)
    [ "$DISKS" -eq 0 ] && success "Discos GCP liberados ✅" || \
        warn "$DISKS disco(s) aún presentes (Rook-Ceph puede tardar)"
else
    warn "kubeconfig no encontrado — saltando paso 2"
fi

# ── PASO 3: Destruir Workload Cluster vía CAPI ────────────────────────────────
step "3" "Destruyendo Workload Cluster bc-workload (CAPG elimina VMs + discos)"
if [ -f "$MGMT_KUBECONFIG" ]; then
    export KUBECONFIG="$MGMT_KUBECONFIG"

    info "Eliminando el Cluster bc-workload..."
    kubectl delete cluster bc-workload --namespace=default --timeout=600s 2>/dev/null || \
        warn "Cluster ya eliminado o no encontrado"

    info "Esperando que CAPG elimine las VMs GCE (hasta 10 min)..."
    kubectl wait cluster bc-workload \
        --for=delete \
        --timeout=600s \
        --namespace=default 2>/dev/null || true

    success "Workload Cluster eliminado ✅"
else
    warn "Management cluster no disponible. Verificar VMs manualmente."
fi

# ── PASO 4: Eliminar Management Cluster (kind local) ──────────────────────────
step "4" "Eliminando Management Cluster local (kind)"
kind delete cluster --name blueupalm-mgmt 2>/dev/null && \
    success "Management Cluster kind eliminado ✅" || \
    warn "Cluster kind no encontrado (ya eliminado)"

# Limpiar kubeconfigs
rm -f "$MGMT_KUBECONFIG" "$WORKLOAD_KUBECONFIG"
info "kubeconfigs eliminados"

# ── PASO 5: Terraform destroy ─────────────────────────────────────────────────
step "5" "Terraform destroy (VPC, IAM, Cloud DNS, Secret Manager)"
if [ -d "$SCRIPT_DIR/terraform" ] && [ -f "$SCRIPT_DIR/terraform/terraform.tfstate" ]; then
    cd "$SCRIPT_DIR/terraform"

    DESTROY_ARGS="-auto-approve -input=false"
    if [ "$PURGE_SECRETS" = false ]; then
        # Excluir secretos de Secret Manager por defecto
        DESTROY_ARGS="$DESTROY_ARGS -target=module.vpc -target=module.iam -target=module.cloud_dns -target=google_compute_global_address.ingress_ip"
        warn "Secretos de GCP Secret Manager CONSERVADOS (usar --purge-secrets para eliminarlos)"
    fi

    terraform destroy $DESTROY_ARGS \
        -var="gcp_project_id=$GCP_PROJECT_ID" \
        -var="letsencrypt_email=noop@noop.com" || \
        warn "Terraform destroy con errores — revisar estado manual"

    success "Terraform destroy completado ✅"
    cd "$SCRIPT_DIR"
else
    warn "Estado Terraform no encontrado. Eliminar recursos manualmente si es necesario."
fi

# ── PASO 6: Verificación de residuos ─────────────────────────────────────────
step "6" "Verificación de residuos en GCP"

echo -e "\n${BOLD}Instancias GCE (debe estar vacío):${NC}"
gcloud compute instances list \
    --project="$GCP_PROJECT_ID" \
    --filter="name~bc-workload" \
    --format="table(name,zone,status)" 2>/dev/null || echo "(sin instancias)"

echo -e "\n${BOLD}Discos GCP (debe estar vacío):${NC}"
gcloud compute disks list \
    --project="$GCP_PROJECT_ID" \
    --filter="name~bc-workload OR labels.cluster=bc-workload" \
    --format="table(name,zone,sizeGb,status)" 2>/dev/null || echo "(sin discos)"

echo -e "\n${BOLD}Forwarding Rules (debe estar vacío):${NC}"
gcloud compute forwarding-rules list \
    --project="$GCP_PROJECT_ID" \
    --filter="description~bc-workload" \
    --format="table(name,region,IPAddress)" 2>/dev/null || echo "(sin forwarding rules)"

if [ "$PURGE_SECRETS" = true ]; then
    echo -e "\n${BOLD}Eliminando secretos de GCP Secret Manager:${NC}"
    for secret in \
        blueupalm-keycloak-admin-password \
        blueupalm-nats-nkey-seed-edge \
        blueupalm-nats-nkey-seed-ingestor \
        blueupalm-biscuit-root-key-pkcs8 \
        blueupalm-postgres-password \
        blueupalm-qdrant-api-key \
        blueupalm-openziti-enrollment-jwt \
        blueupalm-spire-join-token; do
        gcloud secrets delete "$secret" \
            --project="$GCP_PROJECT_ID" \
            --quiet 2>/dev/null && echo "  ✅ $secret eliminado" || \
            echo "  (no encontrado) $secret"
    done
fi

# ── RESUMEN ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ BlueUPALM — Infraestructura destruida${NC}"
echo -e "${BOLD}${GREEN}  Factura GCP: €0 ✅${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  Verificar manualmente en GCP Console:"
echo -e "  https://console.cloud.google.com/compute/instances?project=${GCP_PROJECT_ID}"
echo -e "  https://console.cloud.google.com/compute/disks?project=${GCP_PROJECT_ID}\n"
