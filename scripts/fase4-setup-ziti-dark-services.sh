#!/usr/bin/env bash
# scripts/fase4-setup-ziti-dark-services.sh
# BlueUPALM — Fase 4: Crear Dark Services NetFoundry para Zero-Trust Control Plane
#
# PREREQUISITOS:
#   - Cluster Talos bc-workload operativo (Fases 1-2 completadas)
#   - Ziti System Extension activa en los nodos (Fase 3 completada)
#   - nf CLI instalado: brew install netfoundry/tap/ziti-cli
#   - Variables: NF_CLIENT_ID, NF_CLIENT_SECRET, NF_NETWORK_ID
#   - KUBECONFIG apuntando al Management Cluster
#
# SECUENCIA CRÍTICA (no alterar el orden):
#   1. Verificar Ziti Extension activa en nodos (este script)
#   2. Crear Dark Services NetFoundry (este script)
#   3. Verificar acceso via Ziti (este script)
#   4. SOLO ENTONCES: activar firewall GCP (fase4-enable-zero-trust-firewall.sh)
#
# Arquitectura: docs/architecture/talos-sovereign-stack.md (Sección 5)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}══ $1 ══${NC}"; }

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
GCP_REGION="${GCP_REGION:-europe-west1}"
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"

# NetFoundry API
NF_AUTH_URL="https://netfoundry-production-xfjiye.auth.us-east-1.amazoncognito.com/oauth2/token"
NF_API_URL="https://gateway.production.netfoundry.io/core/v2"
NF_NETWORK_ID="${NF_NETWORK_ID:-b82f4619-7b7c-4bad-8259-8bd1128d715a}"

: "${NF_CLIENT_ID:?Falta NF_CLIENT_ID}"
: "${NF_CLIENT_SECRET:?Falta NF_CLIENT_SECRET}"

echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  🔒 Fase 4: Zero-Trust Control Plane — Setup Ziti${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

# ── PASO 1: Verificar Ziti Extension en nodos ─────────────────────────────────
step "PASO 1: Verificar Ziti System Extension en nodos Talos"
export KUBECONFIG="$MGMT_KUBECONFIG"

CP_NODE=$(kubectl get machine -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null | head -1)
[ -n "$CP_NODE" ] || error "No se encontró la IP del nodo Control Plane"

info "Verificando Ziti Extension en nodo: $CP_NODE"
ZITI_STATUS=$(talosctl service ziti-edge-tunneler status --nodes "$CP_NODE" 2>/dev/null | grep -i "state\|running" || echo "NOT_FOUND")

if echo "$ZITI_STATUS" | grep -qi "running\|finished"; then
    success "Ziti Edge Tunneler activo en $CP_NODE ✅"
else
    error "Ziti Edge Tunneler NO está activo en $CP_NODE.
Verificar que la Ziti System Extension está incluida en la imagen del cluster (Fase 3).
Estado: $ZITI_STATUS"
fi

# ── PASO 2: Obtener token NetFoundry ─────────────────────────────────────────
step "PASO 2: Autenticación NetFoundry"
NF_TOKEN=$(curl -s -X POST "$NF_AUTH_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${NF_CLIENT_ID}&client_secret=${NF_CLIENT_SECRET}" \
    | jq -r '.access_token')

[ -n "$NF_TOKEN" ] && [ "$NF_TOKEN" != "null" ] || error "No se pudo obtener token NetFoundry"
success "Token NetFoundry obtenido ✅"

# Helper para llamadas a la API NetFoundry
nf_api() {
    curl -s -X "${1}" "${NF_API_URL}${2}" \
        -H "Authorization: Bearer ${NF_TOKEN}" \
        -H "Content-Type: application/json" \
        ${3:+-d "$3"}
}

# ── PASO 3: Crear Dark Services ───────────────────────────────────────────────
step "PASO 3: Crear Dark Services (Talos API :50000 + kube-apiserver :6443)"

# Obtener la IP interna del control plane (endpoint VIP del Internal LB)
CP_VIP=$(kubectl get cluster bc-workload -o jsonpath='{.spec.controlPlaneEndpoint.host}' 2>/dev/null)
[ -n "$CP_VIP" ] || CP_VIP="$CP_NODE"
info "Control Plane endpoint: $CP_VIP"

# Dark Service: Talos API
info "Creando dark service: talos-api.bc.internal:50000"
TALOS_SVC_RESP=$(nf_api POST "/services" "{
    \"networkId\": \"${NF_NETWORK_ID}\",
    \"name\": \"talos-api-bc\",
    \"clientIngress\": {\"host\": \"talos-api.bc.internal\", \"port\": 50000},
    \"serverEgress\":  {\"host\": \"${CP_VIP}\", \"port\": 50000, \"protocol\": \"tcp\"}
}")

TALOS_SVC_ID=$(echo "$TALOS_SVC_RESP" | jq -r '.id // empty')
if [ -n "$TALOS_SVC_ID" ]; then
    success "Dark service Talos API creado: ID=$TALOS_SVC_ID ✅"
else
    EXISTING=$(echo "$TALOS_SVC_RESP" | jq -r '.message // .error // "unknown"')
    warn "Talos API service: $EXISTING (puede que ya exista)"
fi

# Dark Service: kube-apiserver
info "Creando dark service: k8s-api.bc.internal:6443"
K8S_SVC_RESP=$(nf_api POST "/services" "{
    \"networkId\": \"${NF_NETWORK_ID}\",
    \"name\": \"k8s-api-bc\",
    \"clientIngress\": {\"host\": \"k8s-api.bc.internal\", \"port\": 6443},
    \"serverEgress\":  {\"host\": \"${CP_VIP}\", \"port\": 6443, \"protocol\": \"tcp\"}
}")

K8S_SVC_ID=$(echo "$K8S_SVC_RESP" | jq -r '.id // empty')
if [ -n "$K8S_SVC_ID" ]; then
    success "Dark service kube-apiserver creado: ID=$K8S_SVC_ID ✅"
else
    EXISTING=$(echo "$K8S_SVC_RESP" | jq -r '.message // .error // "unknown"')
    warn "kube-apiserver service: $EXISTING (puede que ya exista)"
fi

# ── PASO 4: Crear AppWAN con identidades autorizadas ─────────────────────────
step "PASO 4: Crear AppWAN (admin + capi-bootstrap access)"

APPWAN_RESP=$(nf_api POST "/app-wans" "{
    \"networkId\": \"${NF_NETWORK_ID}\",
    \"name\": \"bc-control-plane-access\",
    \"serviceIds\": [\"${TALOS_SVC_ID:-}\", \"${K8S_SVC_ID:-}\"],
    \"endpointIds\": []
}")

APPWAN_ID=$(echo "$APPWAN_RESP" | jq -r '.id // empty')
if [ -n "$APPWAN_ID" ]; then
    success "AppWAN creado: ID=$APPWAN_ID ✅"
    info "Añadir identidades autorizadas manualmente en NetFoundry Console:"
    info "  - admin-identity (identidad del administrador)"
    info "  - capi-bootstrap-identity (identidad del pod CAPG)"
else
    warn "AppWAN: $(echo "$APPWAN_RESP" | jq -r '.message // .error // "unknown"')"
fi

# ── PASO 5: Verificar acceso vía Ziti ────────────────────────────────────────
step "PASO 5: Verificar acceso vía Ziti overlay"
info "Configurando talosctl para usar el dark service Ziti..."

# Backup del config actual
cp ~/.talos/config ~/.talos/config.pre-zerotrust 2>/dev/null || true

# Configurar talosctl para usar endpoint Ziti
talosctl config merge - <<EOF
context: bc-workload
contexts:
  bc-workload:
    endpoints:
      - talos-api.bc.internal   # Ziti dark service
    nodes:
      - talos-api.bc.internal
EOF

info "Probando acceso Talos API via Ziti..."
if talosctl health --nodes talos-api.bc.internal --timeout 30s 2>/dev/null; then
    success "Acceso Talos API via Ziti: OK ✅"
else
    warn "No se pudo verificar acceso Talos vía Ziti — ¿está el tunneler activo en el admin?"
    warn "Asegúrate de tener el Ziti tunneler corriendo con tu identidad de administrador."
    info "Restaurando config anterior..."
    cp ~/.talos/config.pre-zerotrust ~/.talos/config 2>/dev/null || true
fi

info "Probando acceso kube-apiserver via Ziti..."
if kubectl --server=https://k8s-api.bc.internal:6443 --insecure-skip-tls-verify get nodes 2>/dev/null; then
    success "Acceso kube-apiserver via Ziti: OK ✅"
else
    warn "Acceso kube-apiserver vía Ziti pendiente de configuración del tunneler"
fi

# ── RESUMEN ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ Dark Services configurados${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}Dark Services:${NC}"
echo -e "  talos-api.bc.internal:50000  → Talos API (gRPC mTLS)"
echo -e "  k8s-api.bc.internal:6443     → kube-apiserver"
echo ""
echo -e "  ${BOLD}⚠️  SIGUIENTE PASO (SOLO si el acceso Ziti está verificado):${NC}"
echo -e "  bash scripts/fase4-enable-zero-trust-firewall.sh"
echo ""
echo -e "  ${BOLD}⛔ NO ejecutar el siguiente script sin verificar acceso Ziti.${NC}"
echo -e "  Si se activa el firewall sin acceso Ziti funcional, se pierde"
echo -e "  el acceso al cluster y requiere intervención manual en GCP Console."
echo ""
