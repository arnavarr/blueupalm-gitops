#!/usr/bin/env bash
# bootstrap/01-install-local-deps.sh
# BlueUPALM — Instalación de dependencias en Mac (Management cluster local)
#
# Instala todas las herramientas necesarias para gestionar el Workload Cluster
# desde tu Mac, evitando el coste de una VM de gestión en GCP.
#
# PREREQUISITOS:
#   - Homebrew instalado (https://brew.sh)
#   - gcloud CLI instalado y autenticado: gcloud auth application-default login
#
# USO: bash bootstrap/01-install-local-deps.sh

set -euo pipefail

# ── Colores para output legible en demo ───────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  BlueUPALM — Bootstrap: Instalación de dependencias"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Verificar Homebrew ────────────────────────────────────────────────────────
command -v brew &>/dev/null || error "Homebrew no encontrado. Instalar en https://brew.sh"

# ── Función de instalación idempotente ────────────────────────────────────────
install_brew() {
    local pkg="$1"
    if brew list "$pkg" &>/dev/null; then
        success "$pkg ya instalado ($(brew list --versions "$pkg" | awk '{print $2}'))"
    else
        info "Instalando $pkg..."
        brew install "$pkg"
        success "$pkg instalado"
    fi
}

# ── Herramientas de Kubernetes ────────────────────────────────────────────────
info "=== Herramientas Kubernetes ==="
install_brew kubectl
install_brew kind
install_brew helm
install_brew fluxcd/tap/flux

# ── Cluster API ───────────────────────────────────────────────────────────────
info "=== Cluster API ==="
if command -v clusterctl &>/dev/null; then
    success "clusterctl ya instalado ($(clusterctl version --output short 2>/dev/null || echo 'unknown'))"
else
    info "Instalando clusterctl..."
    CLUSTERCTL_VERSION="v1.7.0"
    curl -sL "https://github.com/kubernetes-sigs/cluster-api/releases/download/${CLUSTERCTL_VERSION}/clusterctl-darwin-arm64" \
        -o /usr/local/bin/clusterctl
    chmod +x /usr/local/bin/clusterctl
    success "clusterctl ${CLUSTERCTL_VERSION} instalado"
fi

# ── Herramientas de datos y secretos ─────────────────────────────────────────
info "=== Herramientas auxiliares ==="
install_brew jq
install_brew yq
install_brew nats-io/nats-tools/nats   # CLI para validar streams NATS

# ── Verificar gcloud ──────────────────────────────────────────────────────────
info "=== Google Cloud CLI ==="
command -v gcloud &>/dev/null || error "gcloud CLI no instalado. Ver: https://cloud.google.com/sdk/install"
GCLOUD_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [ -z "$GCLOUD_ACCOUNT" ]; then
    warn "No hay cuenta gcloud activa. Ejecutar: gcloud auth application-default login"
else
    success "gcloud autenticado como: $GCLOUD_ACCOUNT"
fi

# ── Crear kubeconfig para el Management Cluster (kind) ───────────────────────
info "=== Creando Management Cluster kind ==="
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"

if kind get clusters 2>/dev/null | grep -q "^blueupalm-mgmt$"; then
    success "Cluster kind 'blueupalm-mgmt' ya existe"
else
    info "Creando cluster kind 'blueupalm-mgmt'..."
    cat <<EOF | kind create cluster --name blueupalm-mgmt --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        node-labels: "ingress-ready=true"
EOF
    success "Cluster kind 'blueupalm-mgmt' creado"
fi

kind get kubeconfig --name blueupalm-mgmt > "$MGMT_KUBECONFIG"
chmod 600 "$MGMT_KUBECONFIG"
success "kubeconfig guardado en $MGMT_KUBECONFIG"

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Dependencias instaladas correctamente"
echo ""
echo "  Management cluster: KUBECONFIG=$MGMT_KUBECONFIG"
echo "  Próximo paso:       bash bootstrap/02-init-capg.sh"
echo "═══════════════════════════════════════════════════════"
echo ""
