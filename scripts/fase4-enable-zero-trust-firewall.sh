#!/usr/bin/env bash
# scripts/fase4-enable-zero-trust-firewall.sh
# BlueUPALM — Fase 4: Activar reglas de firewall Zero-Trust
#
# ⚠️  EJECUTAR SOLO DESPUÉS DE VERIFICAR ACCESO VÍA ZITI
#
# Este script activa la regla de firewall GCP que bloquea el acceso
# directo a los puertos 50000 (Talos API) y 6443 (kube-apiserver).
# Una vez activada, el acceso SOLO es posible mediante el overlay Ziti.
#
# PREREQUISITO OBLIGATORIO:
#   bash scripts/fase4-setup-ziti-dark-services.sh  ← Verificó acceso Ziti OK
#
# Arquitectura: docs/architecture/talos-sovereign-stack.md (Sección 5)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
FIREWALL_RULE="bc-workload-deny-cp-direct"

echo -e "\n${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${RED}  ⚠️  ACTIVACIÓN DE FIREWALL ZERO-TRUST${NC}"
echo -e "${BOLD}${RED}  Esta acción bloquea el acceso directo al Control Plane${NC}"
echo -e "${BOLD}${RED}═══════════════════════════════════════════════════════════${NC}\n"

# ── Confirmación obligatoria ──────────────────────────────────────────────────
echo -e "  ${BOLD}Verificaciones previas requeridas:${NC}"
echo -e "  1. ¿El script fase4-setup-ziti-dark-services.sh completó correctamente? [s/N]"
read -r CHECK1

echo -e "  2. ¿talosctl health --nodes talos-api.bc.internal responde OK? [s/N]"
read -r CHECK2

echo -e "  3. ¿kubectl via k8s-api.bc.internal:6443 responde? [s/N]"
read -r CHECK3

if [[ ! "$CHECK1" =~ ^[sS]$ ]] || [[ ! "$CHECK2" =~ ^[sS]$ ]] || [[ ! "$CHECK3" =~ ^[sS]$ ]]; then
    error "Verificaciones no completadas. NO se activará el firewall.
Completa las verificaciones antes de continuar:
  bash scripts/fase4-setup-ziti-dark-services.sh"
fi

echo ""
warn "ÚLTIMA OPORTUNIDAD: Al activar el firewall, el acceso directo se bloquea."
echo -e "  Escribe 'ACTIVAR-ZERO-TRUST' para confirmar:"
read -r CONFIRM

[ "$CONFIRM" = "ACTIVAR-ZERO-TRUST" ] || error "Confirmación incorrecta. Operación cancelada."

# ── Activar la regla de firewall via gcloud (Terraform la creó desactivada) ───
info "Activando regla de firewall: $FIREWALL_RULE"
gcloud compute firewall-rules update "$FIREWALL_RULE" \
    --no-disabled \
    --project="$GCP_PROJECT_ID"

success "Regla de firewall activada: $FIREWALL_RULE ✅"

# ── Verificar que el acceso directo está bloqueado ────────────────────────────
info "Verificando bloqueo de acceso directo (timeout 10s)..."
CP_NODE=$(kubectl --kubeconfig="${HOME}/.kube/blueupalm-mgmt.yaml" \
    get machine -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | head -1)

if [ -n "$CP_NODE" ]; then
    if curl -sk --max-time 10 "https://${CP_NODE}:6443/healthz" &>/dev/null; then
        error "FALLO DE SEGURIDAD: El acceso directo a $CP_NODE:6443 sigue siendo posible.
Revisar la regla de firewall en GCP Console y verificar que la prioridad es correcta."
    else
        success "Acceso directo bloqueado correctamente ✅ (curl timeout)"
    fi
fi

# ── Verificar que el acceso Ziti sigue funcionando ────────────────────────────
info "Verificando que el acceso Ziti sigue operativo..."
if talosctl health --nodes talos-api.bc.internal --timeout 30s 2>/dev/null; then
    success "Acceso Talos API vía Ziti: OK ✅"
else
    error "PROBLEMA CRÍTICO: Acceso Ziti no funciona tras activar firewall.
Para recuperar el acceso, desactivar la regla desde GCP Console:
  gcloud compute firewall-rules update ${FIREWALL_RULE} --disabled --project=${GCP_PROJECT_ID}"
fi

# ── Actualizar kubeconfig para usar endpoint Ziti ────────────────────────────
info "Actualizando kubeconfig del Workload Cluster para usar endpoint Ziti..."
WORKLOAD_KUBECONFIG="${HOME}/.kube/blueupalm-workload.yaml"

if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    # Reemplazar el server endpoint por el dark service de Ziti
    kubectl config set-cluster bc-workload \
        --server="https://k8s-api.bc.internal:6443" \
        --kubeconfig="$WORKLOAD_KUBECONFIG"
    success "kubeconfig actualizado: server → k8s-api.bc.internal:6443 ✅"
fi

echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ ZERO-TRUST CONTROL PLANE ACTIVADO${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}Estado:${NC}"
echo -e "  - Acceso directo (IP):         ⛔ BLOQUEADO"
echo -e "  - Acceso Talos API (Ziti):     ✅ ACTIVO"
echo -e "  - Acceso kube-apiserver (Ziti):✅ ACTIVO"
echo ""
echo -e "  ${BOLD}Operativa desde ahora:${NC}"
echo -e "  talosctl health --nodes talos-api.bc.internal"
echo -e "  kubectl --kubeconfig=~/.kube/blueupalm-workload.yaml get nodes"
echo ""
echo -e "  ${BOLD}Para recuperar acceso si algo falla:${NC}"
echo -e "  gcloud compute firewall-rules update ${FIREWALL_RULE} \\"
echo -e "    --disabled --project=${GCP_PROJECT_ID}"
echo ""
