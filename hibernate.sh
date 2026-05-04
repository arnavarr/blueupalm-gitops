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

# ── PASO 1: Eliminar Forwarding Rules y LBs GCP ──────────────────────────────
# Fix INC-003: limpieza directa vía gcloud, sin depender del kubeconfig del Workload
step "1" "Eliminando Forwarding Rules y LBs GCP (ahorro directo, sin kubeconfig)"

info "Buscando Forwarding Rules asociadas al cluster bc-workload..."
FWD_RULES=$(gcloud compute forwarding-rules list \
    --project="$GCP_PROJECT_ID" \
    --format="value(name,region)" 2>/dev/null | grep -i "bc-workload" || true)

if [ -n "$FWD_RULES" ]; then
    while IFS=$'\t' read -r NAME REGION; do
        [ -z "$NAME" ] && continue
        info "Eliminando forwarding-rule: $NAME (region: $REGION)"
        gcloud compute forwarding-rules delete "$NAME" \
            --region="$REGION" \
            --project="$GCP_PROJECT_ID" \
            --quiet 2>/dev/null || true
    done <<< "$FWD_RULES"
    success "Forwarding Rules eliminadas ✅"
else
    success "No hay Forwarding Rules activas de bc-workload ✅"
fi

# Complementario: si el kubeconfig está disponible, borrar también vía K8s
if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    info "kubeconfig disponible — eliminando Services LoadBalancer vía K8s..."
    $KUBECTL_WC get svc -A --no-headers 2>/dev/null | awk '{print $1, $2}' | \
    while read -r ns name; do
        TYPE=$($KUBECTL_WC get svc -n "$ns" "$name" -o jsonpath='{.spec.type}' 2>/dev/null || echo "")
        [ "$TYPE" = "LoadBalancer" ] && \
            $KUBECTL_WC delete svc -n "$ns" "$name" --wait=false 2>/dev/null || true
    done
    sleep 10
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
step "4" "Eliminando Management Cluster local (Talos/OrbStack o kind)"

# Intentar con talosctl primero (Fase 1+)
if command -v talosctl &>/dev/null && talosctl config info --context blueupalm-mgmt &>/dev/null 2>&1; then
    talosctl cluster destroy --name blueupalm-mgmt 2>/dev/null && \
        success "Management Cluster Talos eliminado ✅" || warn "talosctl destroy falló — puede que ya no existiera"
# Fallback: kind (mientras se migra a Talos)
elif command -v kind &>/dev/null; then
    kind delete cluster --name blueupalm-mgmt 2>/dev/null && \
        success "Management Cluster kind eliminado ✅" || warn "kind cluster no existía"
else
    warn "No se encontró talosctl ni kind — Management Cluster puede seguir activo"
fi

rm -f "$MGMT_KUBECONFIG" "$WORKLOAD_KUBECONFIG"

# ── PASO 5: Limpiar LBs GCP directamente via gcloud (Fix INC-003) ────────────
# Si el kubeconfig no existía, los Forwarding Rules quedan huérfanos.
# Este paso los elimina directamente sin necesitar kubeconfig.
step "5" "Limpieza directa de Forwarding Rules y Backend Services GCP"
for fr in $(gcloud compute forwarding-rules list --project="$GCP_PROJECT_ID" \
    --filter="name~bc-workload" --format="value(name,region)" 2>/dev/null | awk '{print $1"|"$2}'); do
    NAME=$(echo "$fr" | cut -d'|' -f1)
    REGION=$(echo "$fr" | cut -d'|' -f2)
    info "Eliminando Forwarding Rule: $NAME (región: $REGION)"
    gcloud compute forwarding-rules delete "$NAME" --region="$REGION" \
        --project="$GCP_PROJECT_ID" --quiet 2>/dev/null && \
        success "  $NAME eliminado" || warn "  $NAME ya no existía"
done

for bs in $(gcloud compute backend-services list --project="$GCP_PROJECT_ID" \
    --filter="name~bc-workload" --format="value(name,region)" 2>/dev/null | awk '{print $1"|"$2}'); do
    NAME=$(echo "$bs" | cut -d'|' -f1)
    REGION=$(echo "$bs" | cut -d'|' -f2)
    info "Eliminando Backend Service: $NAME"
    gcloud compute backend-services delete "$NAME" --region="$REGION" \
        --project="$GCP_PROJECT_ID" --quiet 2>/dev/null && \
        success "  $NAME eliminado" || warn "  $NAME ya no existía"
done

# Verificar VMs residuales (CAPG puede tardar ~5 min en eliminarlas)
VMS=$(gcloud compute instances list --project="$GCP_PROJECT_ID" \
    --filter="name~bc-workload" --format="value(name)" 2>/dev/null | wc -l | tr -d ' ')
if [ "$VMS" -gt 0 ]; then
    warn "$VMS VM(s) aún en eliminación (CAPG async). Verificar en 5 min:"
    warn "  gcloud compute instances list --project=$GCP_PROJECT_ID"
else
    success "No quedan VMs GCE activas ✅"
fi

# ── PASO 6: Borrar la dirección IP ziti-ip ────────────────────────────────────
step "6" "Limpieza de dirección IP estática ziti-ip"
info "Buscando y eliminando IP estática ziti-ip en todas las regiones..."

ZITI_IP_INFO=$(gcloud compute addresses list --project="$GCP_PROJECT_ID" --filter="name=ziti-ip" --format="value(name,region)" 2>/dev/null || true)

if [ -n "$ZITI_IP_INFO" ]; then
    while IFS=$'\t' read -r NAME REGION; do
        [ -z "$NAME" ] && continue
        info "Eliminando IP estática: $NAME (región: $REGION)"
        gcloud compute addresses delete "$NAME" --region="$REGION" --project="$GCP_PROJECT_ID" --quiet 2>/dev/null && \
            success "IP $NAME eliminada ✅" || warn "No se pudo eliminar la IP $NAME"
    done <<< "$ZITI_IP_INFO"
else
    success "IP ziti-ip no encontrada o ya no existía ✅"
fi

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
echo -e "  - Dirección IP estática ziti-ip"
echo ""
echo -e "  ${BOLD}PRÓXIMA SESIÓN:${NC}"
echo -e "  1. bash setup_all.sh   (Se saltará Terraform e Imagen GCE si existen)"
echo -e "  2. El cluster se redesplegará en ~10 min en lugar de ~30 min."
echo ""
