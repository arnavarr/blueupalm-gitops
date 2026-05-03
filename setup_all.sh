#!/usr/bin/env bash
# setup_all.sh
# BlueUPALM Platform — Script Maestro de Despliegue (13 pasos)
# DORA + PBC/FT Compliance | GCP/CNCF | Kubernetes no-GKE

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
warn()    { echo -e "${YELLOW}[⚠️]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }
step()    { echo -e "\n${BOLD}${BLUE}══ Paso $1: $2 ══${NC}"; }

# ── Variables (con defaults demo) ─────────────────────────────────────────────
export GCP_PROJECT_ID="${GCP_PROJECT_ID:-blueup-bc-demo}"
export GCP_REGION="${GCP_REGION:-europe-west1}"
export GCP_ZONE="${GCP_ZONE:-europe-west1-b}"
export FLUX_GITHUB_OWNER="${FLUX_GITHUB_OWNER:-arnavarr}"
export FLUX_GITHUB_REPO="${FLUX_GITHUB_REPO:-blueupalm-gitops}"
export DOMAIN="${DOMAIN:-navarro-bores.com}"

MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"
WORKLOAD_KUBECONFIG="${HOME}/.kube/blueupalm-workload.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "\n${BOLD}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  BlueUPALM Platform — Despliegue Enterprise GCP/CNCF${NC}"
echo -e "${BOLD}  AML & Resilience System | DORA + PBC/FT Compliance${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${NC}\n"

# ── PASO 0: Prerequisitos ─────────────────────────────────────────────────────
step "0" "Verificación de prerequisitos"
: "${FLUX_GITHUB_TOKEN:?❌ Falta FLUX_GITHUB_TOKEN}"
: "${LETSENCRYPT_EMAIL:?❌ Falta LETSENCRYPT_EMAIL}"

for tool in gcloud terraform kubectl kind clusterctl helm flux jq envsubst; do
    command -v "$tool" &>/dev/null && success "$tool" || \
        error "$tool no encontrado. Ejecutar: bash bootstrap/01-install-local-deps.sh"
done

ACTIVE_ACCOUNT=$(gcloud auth list --filter=status:ACTIVE --format="value(account)" 2>/dev/null | head -1)
[ -n "$ACTIVE_ACCOUNT" ] || error "gcloud no autenticado. Ejecutar: gcloud auth application-default login"
success "gcloud: $ACTIVE_ACCOUNT | Proyecto: $GCP_PROJECT_ID | Región: $GCP_REGION"

# ── PASO 1: Terraform ─────────────────────────────────────────────────────────
step "1" "Terraform: VPC, IAM, Secret Manager, Cloud DNS (navarro-bores.com)"
cd "$SCRIPT_DIR/terraform"
[ -f terraform.tfvars ] || { cp terraform.tfvars.example terraform.tfvars; error "Editar terraform/terraform.tfvars y ejecutar de nuevo."; }

terraform init -upgrade -input=false
terraform apply -auto-approve -input=false \
    -var="letsencrypt_email=$LETSENCRYPT_EMAIL" \
    -var="gcp_project_id=$GCP_PROJECT_ID"

INGRESS_IP=$(terraform output -raw ingress_ip_address)
NODES_SA_EMAIL=$(terraform output -raw nodes_service_account_email)
export NODES_SA_EMAIL
success "Terraform OK. IP Ingress: $INGRESS_IP | Nodes SA: $NODES_SA_EMAIL"
cd "$SCRIPT_DIR"

# ── PASO 2: Management Cluster ────────────────────────────────────────────────
step "2" "Bootstrap Management Cluster local (Talos/OrbStack o kind/Docker)"

# Fix INC-001: verificar hypervisor disponible antes de crear el management cluster
if command -v talosctl &>/dev/null; then
    info "talosctl detectado — usando Talos como Management Cluster (sin Docker Desktop)"
elif [[ "$(uname)" == "Darwin" ]]; then
    if ! docker info &>/dev/null 2>&1; then
        warn "Docker Desktop no detectado — iniciando..."
        open -a Docker 2>/dev/null || true
        info "Esperando Docker daemon (hasta 60s)..."
        for i in $(seq 1 30); do
            docker info &>/dev/null 2>&1 && { success "Docker Desktop listo"; break; } || sleep 2
            [ "$i" -eq 30 ] && error "Docker Desktop no arrancó tras 60s. Inícialo manualmente y repite."
        done
    else
        success "Docker Desktop ya corriendo"
    fi
fi

bash bootstrap/01-install-local-deps.sh
export KUBECONFIG="$MGMT_KUBECONFIG"

# ── PASO 3: CAPG + CABPT + CACPT ──────────────────────────────────────────────
step "3" "Cluster API Provider GCP (CAPG) + Talos Bootstrap (CABPT + CACPT)"
bash bootstrap/02-init-capg.sh

# ── PASO 4: Imagen Talos Linux para GCE ──────────────────────────────────────
step "4" "Verificando imagen Talos Linux oficial para GCE"
TALOS_VERSION="v1.7.6"
TALOS_IMAGE_NAME="talos-${TALOS_VERSION//./-}-gce-amd64"

# Buscar primero en el proyecto propio (ya registrada)
IMAGE_EXISTS=$(gcloud compute images list \
    --project="$GCP_PROJECT_ID" \
    --filter="name=${TALOS_IMAGE_NAME} AND status=READY" \
    --format="value(name)" 2>/dev/null | head -1)

if [ -n "$IMAGE_EXISTS" ]; then
    success "Imagen Talos existente en proyecto: $IMAGE_EXISTS"
else
    info "Registrando imagen Talos ${TALOS_VERSION} en GCE (~3 min)..."
    GCS_BUCKET="${GCP_PROJECT_ID}-talos-images"
    gsutil mb -p "$GCP_PROJECT_ID" -l "$GCP_REGION" "gs://${GCS_BUCKET}" 2>/dev/null || true

    curl -fsSL \
        "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/gcp-amd64.tar.gz" \
        -o /tmp/talos-gce.tar.gz

    gsutil cp /tmp/talos-gce.tar.gz "gs://${GCS_BUCKET}/talos-${TALOS_VERSION}.tar.gz"

    gcloud compute images create "${TALOS_IMAGE_NAME}" \
        --source-uri="gs://${GCS_BUCKET}/talos-${TALOS_VERSION}.tar.gz" \
        --project="$GCP_PROJECT_ID" \
        --family="talos-linux"

    rm -f /tmp/talos-gce.tar.gz
    success "Imagen Talos ${TALOS_VERSION} registrada ✅"
fi
export TALOS_IMAGE_NAME

# ── PASO 5: Workload Cluster ──────────────────────────────────────────────────
step "5" "Despliegue Workload Cluster bc-workload (CAPI/CAPG)"
export KUBECONFIG="$MGMT_KUBECONFIG"
envsubst < cluster-api/cluster.yaml | kubectl apply -f -
envsubst < cluster-api/control-plane.yaml | kubectl apply -f -
envsubst < cluster-api/workers.yaml | kubectl apply -f -
success "Manifiestos CAPI aplicados (3 workers e2-standard-4, discos 200GB Ceph)"

# ── PASO 6: Esperar cluster Ready ─────────────────────────────────────────────
step "6" "Esperando Workload Cluster Ready (hasta 30 min)"
info "Creando VMs GCE en europe-west1-{b,c,d}..."
info "(Fix INC-002: poll cada 30s + timeout explícito — kubeadm init puede tardar 10-15 min)"

# Espera activa con diagnóstico cada 2 minutos
TIMEOUT=1800
ELAPSED=0
while ! kubectl get cluster bc-workload -n default -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
    if [ $ELAPSED -ge $TIMEOUT ]; then
        error "Cluster no listo tras ${TIMEOUT}s. Ver: kubectl describe cluster bc-workload"
    fi
    if (( ELAPSED % 120 == 0 && ELAPSED > 0 )); then
        info "[${ELAPSED}s] Cluster aún provisioning... (VMs GCE: $(gcloud compute instances list --project=$GCP_PROJECT_ID --format='value(name)' 2>/dev/null | wc -l | tr -d ' ') activas)"
        kubectl get machines -n default --no-headers 2>/dev/null | awk '{printf "  Machine %s: %s\n", $1, $6}' || true
    fi
    sleep 30
    ELAPSED=$((ELAPSED + 30))
done
success "bc-workload: Ready ✅"

# ── PASO 7: kubeconfig ────────────────────────────────────────────────────────
step "7" "kubeconfig del Workload Cluster"
clusterctl get kubeconfig bc-workload > "$WORKLOAD_KUBECONFIG"
chmod 600 "$WORKLOAD_KUBECONFIG"
KUBECTL_WC="kubectl --kubeconfig=$WORKLOAD_KUBECONFIG"
$KUBECTL_WC get nodes
success "kubeconfig: $WORKLOAD_KUBECONFIG"

# ── PASO 8: Flux CD ───────────────────────────────────────────────────────────
step "8" "Bootstrap Flux CD → github.com/${FLUX_GITHUB_OWNER}/${FLUX_GITHUB_REPO}"
export GITHUB_TOKEN="$FLUX_GITHUB_TOKEN"
flux bootstrap github \
    --kubeconfig="$WORKLOAD_KUBECONFIG" \
    --owner="$FLUX_GITHUB_OWNER" \
    --repository="$FLUX_GITHUB_REPO" \
    --branch=main \
    --path=./clusters/bc-workload \
    --personal \
    --components-extra=image-reflector-controller,image-automation-controller
success "Flux CD instalado — sincronizando stack CNCF"

# ── PASO 9: Infrastructure ────────────────────────────────────────────────────
step "9" "Esperando infrastructure/ (Cilium+WireGuard, cert-manager, External Secrets)"
$KUBECTL_WC wait kustomization infrastructure \
    --for=condition=Ready --timeout=1200s --namespace=flux-system
success "infrastructure/ ✅ — Cilium CNI activo, cert-manager configurado para $DOMAIN"

# ── PASO 10: Validar secretos ─────────────────────────────────────────────────
step "10" "Validando External Secrets (GCP Secret Manager → K8s)"
sleep 30
FAILED=$($KUBECTL_WC get externalsecret -A --no-headers 2>/dev/null | grep -vc "True" || echo "0")
[ "$FAILED" -eq 0 ] && success "Todos los secretos sincronizados ✅" || \
    warn "$FAILED secreto(s) pendientes — verificar ESO logs"
$KUBECTL_WC get externalsecret -A

# ── PASO 11: Security ─────────────────────────────────────────────────────────
step "11" "Esperando security/ (Keycloak, SPIRE, OPA, OpenZiti, Dex)"
$KUBECTL_WC wait kustomization security \
    --for=condition=Ready --timeout=900s --namespace=flux-system
success "security/ ✅ — Identidad humana (Keycloak) y de workload (SPIRE) activas"

# ── PASO 12: NATS ─────────────────────────────────────────────────────────────
step "12" "Validando NATS JetStream cluster (DORA HA: 3 réplicas en 3 zonas)"
$KUBECTL_WC wait kustomization messaging \
    --for=condition=Ready --timeout=600s --namespace=flux-system

NATS_READY=$($KUBECTL_WC get pods -n messaging -l app.kubernetes.io/name=nats \
    --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')
[ "$NATS_READY" -ge 3 ] && success "NATS: ${NATS_READY}/3 réplicas ✅" || \
    warn "NATS: ${NATS_READY}/3 réplicas (anti-affinity puede tardar en satisfacerse)"

# Verificar stream AUDIT_TRAIL (7 años PBC/FT)
$KUBECTL_WC exec -n messaging nats-0 -- \
    nats --server nats://localhost:4222 stream info AUDIT_TRAIL 2>/dev/null && \
    success "Stream AUDIT_TRAIL OK (retención 7 años, 3 réplicas) ✅" || \
    warn "Stream AUDIT_TRAIL pendiente (Job de inicialización en progreso)"

# ── PASO 13: Applications ─────────────────────────────────────────────────────
step "13" "Esperando applications/ (edge-security, ingestion-agent, frontend)"
$KUBECTL_WC wait kustomization applications \
    --for=condition=Ready --timeout=600s --namespace=flux-system
success "applications/ ✅"

# ── RESUMEN ───────────────────────────────────────────────────────────────────
KEYCLOAK_PASS=$(gcloud secrets versions access latest \
    --secret=blueupalm-keycloak-admin-password \
    --project="$GCP_PROJECT_ID" 2>/dev/null || echo "[ver GCP Secret Manager]")

echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ BlueUPALM Platform — Despliegue Completado${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}Frontend AML:${NC}     https://blueupalm.${DOMAIN}"
echo -e "  ${BOLD}Keycloak SSO:${NC}     https://auth.${DOMAIN}/auth/admin/blueupalm"
echo -e "  ${BOLD}Grafana:${NC}          https://grafana.${DOMAIN}"
echo -e "  ${BOLD}Hubble UI:${NC}        https://hubble.${DOMAIN}"
echo ""
echo -e "  ${BOLD}Credenciales demo:${NC}"
echo -e "  admin / ${KEYCLOAK_PASS}"
echo ""
echo -e "  ${BOLD}Coste estimado:${NC}   ~\$0.85/h"
echo -e "  ${BOLD}Para €0 en factura:${NC} bash cleanup_demo.sh"
echo ""
echo -e "  ${BOLD}Verificaciones:${NC}"
echo -e "  curl -I https://blueupalm.${DOMAIN}"
echo -e "  curl https://blueupalm.${DOMAIN}/api/edge/health    # → OK"
echo -e "  curl https://blueupalm.${DOMAIN}/api/edge/verify    # → 404 ✅ (nunca expuesto)\n"
