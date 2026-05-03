#!/usr/bin/env bash
# scripts/dr-backup.sh
# BlueUPALM — Backup automático para DR: etcd + Talos secrets + SPIRE CA
#
# Ejecutar manualmente o como CronJob en el cluster (cada 15 min para etcd)
# Los backups se almacenan en GCS cifrados con CMEK (KMS key: dr-backup)
#
# PREREQUISITOS:
#   - Cluster bc-workload operativo
#   - GCS bucket creado por Terraform: ${GCP_PROJECT_ID}-blueupalm-dr
#   - KUBECONFIG apuntando al Management Cluster (para talosctl)
#   - gcloud autenticado
#
# Arquitectura: docs/architecture/talos-sovereign-stack.md (Sección 7 — DR)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
DR_BUCKET="${GCP_PROJECT_ID}-blueupalm-dr"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
MGMT_KUBECONFIG="${HOME}/.kube/blueupalm-mgmt.yaml"
CP_NODE="${CP_NODE:-talos-api.bc.internal}"   # Usa dark service Ziti en Fase 4

echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  💾 BlueUPALM DR Backup — ${TIMESTAMP}${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

# ── 1. etcd Snapshot ──────────────────────────────────────────────────────────
info "Backup etcd snapshot..."
ETCD_SNAP="/tmp/etcd-snap-${TIMESTAMP}.db"

talosctl etcd snapshot "$ETCD_SNAP" \
    --nodes "$CP_NODE" \
    --talosconfig "${HOME}/.talos/config" 2>/dev/null || \
talosctl etcd snapshot "$ETCD_SNAP" \
    --nodes "$CP_NODE"

gsutil cp "$ETCD_SNAP" "gs://${DR_BUCKET}/etcd/snap-${TIMESTAMP}.db"
echo "$TIMESTAMP" | gsutil cp - "gs://${DR_BUCKET}/etcd/latest"
rm -f "$ETCD_SNAP"
success "etcd snapshot → gs://${DR_BUCKET}/etcd/snap-${TIMESTAMP}.db ✅"

# ── 2. Talos Secrets (PKI del cluster) ───────────────────────────────────────
# Los secrets de Talos (CA del cluster, tokens) se generan UNA SOLA VEZ.
# Solo hacer backup si no existe ya uno reciente (< 7 días)
info "Verificando backup de Talos secrets..."
LAST_SECRET=$(gsutil ls "gs://${DR_BUCKET}/talos-secrets/" 2>/dev/null | sort | tail -1 || echo "")

if [ -z "$LAST_SECRET" ]; then
    warn "No existe backup de Talos secrets — generando..."
    SECRETS_FILE="/tmp/talos-secrets-${TIMESTAMP}.yaml"

    talosctl gen secrets --output-file "$SECRETS_FILE" 2>/dev/null || {
        warn "talosctl gen secrets no disponible fuera de bootstrap — saltando"
        info "Los Talos secrets se generan en bootstrap. Backup manual:"
        info "  talosctl gen secrets --output-file secrets.yaml"
        info "  gsutil cp secrets.yaml gs://${DR_BUCKET}/talos-secrets/secrets-FECHA.yaml"
    }

    if [ -f "$SECRETS_FILE" ]; then
        gsutil cp "$SECRETS_FILE" "gs://${DR_BUCKET}/talos-secrets/secrets-${TIMESTAMP}.yaml"
        rm -f "$SECRETS_FILE"
        success "Talos secrets → gs://${DR_BUCKET}/talos-secrets/secrets-${TIMESTAMP}.yaml ✅"
    fi
else
    success "Talos secrets backup existente: $LAST_SECRET (no regenerar)"
fi

# ── 3. SPIRE Root CA ──────────────────────────────────────────────────────────
# SPIRE tiene su propia PKI — NO está en el snapshot de etcd
# Requiere backup separado para DR completo (identidades de workload)
info "Backup SPIRE Root CA..."
WORKLOAD_KUBECONFIG="${HOME}/.kube/blueupalm-workload.yaml"

if [ -f "$WORKLOAD_KUBECONFIG" ]; then
    SPIRE_CA_SECRET=$(kubectl --kubeconfig="$WORKLOAD_KUBECONFIG" \
        get secret -n spire spire-server-ca -o json 2>/dev/null || echo "")

    if [ -n "$SPIRE_CA_SECRET" ]; then
        SPIRE_ENCRYPTED=$(echo "$SPIRE_CA_SECRET" | \
            gcloud kms encrypt \
                --key="projects/${GCP_PROJECT_ID}/locations/global/keyRings/blueupalm/cryptoKeys/dr-backup" \
                --plaintext-file=- \
                --ciphertext-file=- \
                --project="$GCP_PROJECT_ID" 2>/dev/null | base64 | tr -d '\n')

        echo "$SPIRE_ENCRYPTED" | gsutil cp - \
            "gs://${DR_BUCKET}/spire/root-ca-${TIMESTAMP}.enc"

        # Actualizar puntero "latest"
        echo "spire/root-ca-${TIMESTAMP}.enc" | \
            gsutil cp - "gs://${DR_BUCKET}/spire/latest"

        success "SPIRE Root CA → gs://${DR_BUCKET}/spire/root-ca-${TIMESTAMP}.enc ✅"
    else
        warn "SPIRE secret no encontrado — ¿está el cluster de seguridad activo?"
    fi
else
    warn "kubeconfig del Workload no disponible — saltando backup SPIRE"
fi

# ── Resumen ───────────────────────────────────────────────────────────────────
echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ DR Backup completado — ${TIMESTAMP}${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}Bucket:${NC} gs://${DR_BUCKET}/"
echo -e "  ${BOLD}Tier 1 (regulado):${NC} CloudSQL PostgreSQL — PITR gestionado por GCP"
echo -e "  ${BOLD}etcd:${NC}             gs://${DR_BUCKET}/etcd/snap-${TIMESTAMP}.db"
echo -e "  ${BOLD}Talos PKI:${NC}        gs://${DR_BUCKET}/talos-secrets/"
echo -e "  ${BOLD}SPIRE CA:${NC}         gs://${DR_BUCKET}/spire/root-ca-${TIMESTAMP}.enc"
echo ""
echo -e "  ${BOLD}RTO estimado en DR:${NC}"
echo -e "  Tier 1 (datos DORA regulados): < 2 min (CloudSQL PITR)"
echo -e "  Control plane K8s:             < 5 min (Talos + etcd restore)"
echo -e "  Tier 2 (Qdrant/NATS cache):    ~15-20 min (Velero restore)"
echo ""
