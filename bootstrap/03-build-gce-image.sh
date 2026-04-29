#!/usr/bin/env bash
# bootstrap/03-build-gce-image.sh
# BlueUPALM — Construcción de imagen GCE custom para nodos Kubernetes
#
# Crea una imagen GCE basada en Ubuntu 22.04 con:
#   - containerd 1.7.x (runtime de contenedores)
#   - kubeadm / kubelet v1.29.0 (bootstrap K8s)
#   - gVisor (runsc) — runtime de sandboxing principal para datos bancarios
#   - Kata Containers — disponible como RuntimeClass opcional
#
# La imagen es compartida entre el Control Plane y los Workers.
# Los Workers tienen configuración adicional para Rook-Ceph (disco /dev/sdb).
#
# USO: bash bootstrap/03-build-gce-image.sh
# NOTA: Tarda ~10-15 min. Solo necesario una vez o al actualizar versiones.

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[OK]${NC}  $*"; }
error()   { echo -e "${RED}[ERR]${NC}  $*"; exit 1; }

: "${GCP_PROJECT_ID:?Falta GCP_PROJECT_ID}"
: "${GCP_ZONE:=${GCP_ZONE:-europe-west1-b}}"

K8S_VERSION="1.29.0"
CONTAINERD_VERSION="1.7.13"
IMAGE_NAME="blueupalm-k8s-node-$(date +%Y%m%d)"
BUILDER_VM="blueupalm-image-builder"
BUILDER_MACHINE="e2-standard-2"

echo ""
echo "═══════════════════════════════════════════════════════"
echo "  BlueUPALM — Construcción de Imagen GCE Custom"
echo "  K8s: v${K8S_VERSION} | gVisor + Kata | Ubuntu 22.04"
echo "═══════════════════════════════════════════════════════"
echo ""

# ── Crear VM temporal de construcción ─────────────────────────────────────────
info "Creando VM temporal de construcción..."
BUILDER_SA="bc-workload-capg@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
gcloud compute instances create "$BUILDER_VM" \
    --project="$GCP_PROJECT_ID" \
    --zone="$GCP_ZONE" \
    --machine-type="$BUILDER_MACHINE" \
    --image-family=ubuntu-2204-lts \
    --image-project=ubuntu-os-cloud \
    --boot-disk-size=50GB \
    --boot-disk-type=pd-ssd \
    --metadata=enable-oslogin=true \
    --service-account="$BUILDER_SA" \
    --scopes=cloud-platform

# Esperar a que SSH esté disponible
info "Esperando SSH (30s)..."
sleep 30

# ── Script de configuración (se ejecuta en la VM) ─────────────────────────────
SETUP_SCRIPT=$(cat <<'REMOTE_SCRIPT'
#!/bin/bash
set -euo pipefail

K8S_VERSION="1.29.0"
CONTAINERD_VERSION="1.7.13"

echo "[1/6] Actualizando sistema..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq

echo "[2/6] Instalando containerd ${CONTAINERD_VERSION}..."
apt-get install -y -qq apt-transport-https ca-certificates curl gnupg lsb-release
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq containerd.io

# Configuración containerd con múltiples runtimes
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
# Habilitar systemd cgroup driver
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
systemctl enable containerd
systemctl start containerd

echo "[3/6] Instalando kubeadm/kubelet/kubectl v${K8S_VERSION}..."
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.29/deb/Release.key | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.29/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
apt-get update -qq
apt-get install -y -qq "kubelet=${K8S_VERSION}-*" "kubeadm=${K8S_VERSION}-*" "kubectl=${K8S_VERSION}-*"
apt-mark hold kubelet kubeadm kubectl

# Prerequisitos kernel para Kubernetes
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
modprobe overlay && modprobe br_netfilter
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                  = 1
EOF
sysctl --system

echo "[4/6] Instalando gVisor (runsc)..."
curl -fsSL https://gvisor.dev/archive.key | gpg --dearmor -o /usr/share/keyrings/gvisor-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/gvisor-archive-keyring.gpg] https://storage.googleapis.com/gvisor/releases release main" \
    > /etc/apt/sources.list.d/gvisor.list
apt-get update -qq
apt-get install -y -qq runsc

# Configurar gVisor en containerd
cat <<'EOF' >> /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc.options]
    TypeUrl = "io.containerd.runsc.v1.options"
EOF

echo "[5/6] Instalando Kata Containers (opcional, para activación futura)..."
KATA_VERSION="3.2.0"
curl -fsSL "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-amd64.tar.xz" \
    -o /tmp/kata.tar.xz
tar -xf /tmp/kata.tar.xz -C /opt
ln -sf /opt/kata/bin/kata-runtime /usr/local/bin/kata-runtime

# Configurar Kata en containerd
cat <<'EOF' >> /etc/containerd/config.toml

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = "io.containerd.kata.v2"
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
    ConfigPath = "/opt/kata/share/defaults/kata-containers/configuration.toml"
EOF

systemctl restart containerd

echo "[6/6] Limpiando y preparando para captura de imagen..."
apt-get clean
rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
# Limpiar machine-id para que cada VM tenga el suyo propio
echo "" > /etc/machine-id
truncate -s 0 /etc/hostname

echo "✅ Imagen lista para captura"
REMOTE_SCRIPT
)

# ── Ejecutar script en la VM ───────────────────────────────────────────────────
info "Ejecutando configuración en VM (esto tarda ~10 min)..."
echo "$SETUP_SCRIPT" | gcloud compute ssh "$BUILDER_VM" \
    --project="$GCP_PROJECT_ID" \
    --zone="$GCP_ZONE" \
    --command="sudo bash -s"

# ── Detener VM y crear imagen ─────────────────────────────────────────────────
info "Deteniendo VM para crear imagen..."
gcloud compute instances stop "$BUILDER_VM" \
    --project="$GCP_PROJECT_ID" \
    --zone="$GCP_ZONE"

info "Creando imagen GCE '$IMAGE_NAME'..."
gcloud compute images create "$IMAGE_NAME" \
    --project="$GCP_PROJECT_ID" \
    --source-disk="$BUILDER_VM" \
    --source-disk-zone="$GCP_ZONE" \
    --family="blueupalm-k8s-node" \
    --description="BlueUPALM K8s node: Ubuntu 22.04 + kubeadm v${K8S_VERSION} + containerd + gVisor + Kata" \
    --labels="k8s-version=${K8S_VERSION//./-},project=blueupalm,runtime=gvisor-kata"

# ── Limpiar VM temporal ───────────────────────────────────────────────────────
info "Eliminando VM temporal de construcción..."
gcloud compute instances delete "$BUILDER_VM" \
    --project="$GCP_PROJECT_ID" \
    --zone="$GCP_ZONE" \
    --quiet

echo ""
echo "═══════════════════════════════════════════════════════"
success "Imagen creada: $IMAGE_NAME"
echo "  Familia: blueupalm-k8s-node"
echo "  Runtimes: containerd + gVisor (runsc) + Kata (opcional)"
echo ""
echo "  Actualizar cluster-api/workers.yaml con:"
echo "    image: $IMAGE_NAME"
echo "═══════════════════════════════════════════════════════"
echo ""
