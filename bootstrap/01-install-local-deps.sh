#!/usr/bin/env bash
# bootstrap/01-install-local-deps.sh v2 — Talos Management Cluster
# BlueUPALM — Instalación de dependencias en Mac
#
# Crea el Management Cluster usando Talos Linux via OrbStack/QEMU.
# Elimina la dependencia de Docker Desktop (INC-001) y de kind.
#
# PREREQUISITOS:
#   - OrbStack instalado (https://orbstack.dev) ← recomendado (QEMU nativo Apple Silicon)
#   - O bien Docker Desktop como fallback
#   - gcloud CLI instalado y autenticado
#
# USO: bash bootstrap/01-install-local-deps.sh

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  BlueUPALM — Bootstrap: Instalación de dependencias"
echo "  Sovereign Hardened Stack (Talos Linux)"
echo "═══════════════════════════════════════════════════════"
echo ""

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
install_brew helm
install_brew fluxcd/tap/flux

# ── talosctl (reemplaza kind) ─────────────────────────────────────────────────
info "=== Talos Linux CLI ==="
if command -v talosctl &>/dev/null; then
    success "talosctl ya instalado ($(talosctl version --client --short 2>/dev/null || echo 'unknown'))"
else
    info "Instalando talosctl..."
    brew install siderolabs/tap/talosctl
    success "talosctl instalado"
fi

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

# ── Herramientas auxiliares ───────────────────────────────────────────────────
info "=== Herramientas auxiliares ==="
install_brew jq
install_brew yq
install_brew nats-io/nats-tools/nats

# ── Verificar gcloud ──────────────────────────────────────────────────────────
info "=== Google Cloud CLI ==="
command -v gcloud &>/dev/null || error "gcloud CLI no instalado. Ver: https://cloud.google.com/sdk/install"
GCLOUD_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
if [ -z "$GCLOUD_ACCOUNT" ]; then
    warn "No hay cuenta gcloud activa. Ejecutar: gcloud auth application-default login"
else
    success "gcloud autenticado como: $GCLOUD_ACCOUNT"
fi

# ── Crear Management Cluster Talos (reemplaza kind) ──────────────────────────
info "=== Creando Management Cluster Talos ==="
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"

# Verificar si el cluster ya existe
if talosctl config info --context blueupalm-mgmt &>/dev/null 2>&1; then
    success "Cluster Talos 'blueupalm-mgmt' ya existe"
else
    info "Creando cluster Talos local via QEMU (OrbStack)..."

    # QEMU via OrbStack (Apple Silicon — sin Docker Desktop)
    if command -v orb &>/dev/null; then
        PROVISIONER="qemu"
        info "Usando OrbStack/QEMU como provisioner (Apple Hypervisor Framework)"
    else
        # Fallback: Docker como provisioner (requiere Docker Desktop)
        PROVISIONER="docker"
        warn "OrbStack no encontrado — usando Docker como provisioner (fallback)"
        warn "Instalar OrbStack para eliminar dependencia de Docker Desktop: brew install orbstack"
    fi

    talosctl cluster create \
        --name blueupalm-mgmt \
        --provisioner "${PROVISIONER}" \
        --controlplanes 1 \
        --workers 0 \
        --kubernetes-version v1.29.6 \
        --talos-version v1.7.6

    success "Cluster Talos 'blueupalm-mgmt' creado"
fi

# Exportar kubeconfig
MGMT_NODE=$(talosctl config info --context blueupalm-mgmt 2>/dev/null | grep "Endpoints:" | awk '{print $2}' | head -1)
talosctl kubeconfig "$MGMT_KUBECONFIG" \
    --nodes "${MGMT_NODE:-10.5.0.2}" \
    --cluster blueupalm-mgmt \
    --force 2>/dev/null || \
talosctl kubeconfig "$MGMT_KUBECONFIG" \
    --cluster blueupalm-mgmt \
    --force
chmod 600 "$MGMT_KUBECONFIG"
success "kubeconfig guardado en $MGMT_KUBECONFIG"

# ── Resumen ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════"
echo "  ✅ Dependencias instaladas correctamente"
echo ""
echo "  Management cluster: KUBECONFIG=$MGMT_KUBECONFIG"
echo "  OS del cluster:     Talos Linux v1.7.6 (inmutable, sin SSH)"
echo "  Próximo paso:       bash bootstrap/02-init-capg.sh"
echo "═══════════════════════════════════════════════════════"
echo ""
