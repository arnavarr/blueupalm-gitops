#!/usr/bin/env bash
# scripts/fase4-inject-ziti-identity.sh
# BlueUPALM — Fase 4: Cifrar identidad Ziti con KMS e inyectar en MachineConfig
#
# Este script genera una identidad Ziti para los nodos Talos,
# la cifra con GCP KMS y genera el patch para el MachineConfig.
# La identidad se descifra al boot por la Ziti System Extension.
#
# PREREQUISITOS:
#   - terraform apply completado (crea KMS key: ziti-machineconfig-identity)
#   - nf CLI o ziti CLI instalado
#   - NF_CLIENT_ID, NF_CLIENT_SECRET, NF_NETWORK_ID definidos
#   - GCP_PROJECT_ID definido
#
# Arquitectura: docs/architecture/talos-sovereign-stack.md (Sección 5)

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[✅]${NC}   $*"; }
error()   { echo -e "${RED}[❌]${NC}   $*"; exit 1; }

GCP_PROJECT_ID="${GCP_PROJECT_ID:-homelab-466309}"
KMS_KEY="projects/${GCP_PROJECT_ID}/locations/global/keyRings/blueupalm/cryptoKeys/ziti-machineconfig-identity"
OUTPUT_DIR="${PWD}/cluster-api/ziti-identity-patches"
NF_AUTH_URL="https://netfoundry-production-xfjiye.auth.us-east-1.amazoncognito.com/oauth2/token"
NF_API_URL="https://gateway.production.netfoundry.io/core/v2"
NF_NETWORK_ID="${NF_NETWORK_ID:-b82f4619-7b7c-4bad-8259-8bd1128d715a}"

: "${NF_CLIENT_ID:?Falta NF_CLIENT_ID}"
: "${NF_CLIENT_SECRET:?Falta NF_CLIENT_SECRET}"

mkdir -p "$OUTPUT_DIR"

echo -e "\n${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${BLUE}  🔑 Fase 4: Generar e Inyectar Identidad Ziti en MachineConfig${NC}"
echo -e "${BOLD}${BLUE}═══════════════════════════════════════════════════════════${NC}\n"

# ── PASO 1: Obtener token NetFoundry ─────────────────────────────────────────
info "Autenticando con NetFoundry..."
NF_TOKEN=$(curl -s -X POST "$NF_AUTH_URL" \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials&client_id=${NF_CLIENT_ID}&client_secret=${NF_CLIENT_SECRET}" \
    | jq -r '.access_token')
[ -n "$NF_TOKEN" ] && [ "$NF_TOKEN" != "null" ] || error "No se pudo obtener token NetFoundry"
success "Token NetFoundry obtenido"

# ── PASO 2: Crear identidad Ziti para nodos Talos ────────────────────────────
info "Creando identidad Ziti: talos-node-bc-workload"
IDENTITY_RESP=$(curl -s -X POST "${NF_API_URL}/identities" \
    -H "Authorization: Bearer ${NF_TOKEN}" \
    -H "Content-Type: application/json" \
    -d "{
        \"networkId\": \"${NF_NETWORK_ID}\",
        \"name\": \"talos-node-bc-workload\",
        \"type\": \"Device\",
        \"enrollment\": {\"ott\": true}
    }")

IDENTITY_ID=$(echo "$IDENTITY_RESP" | jq -r '.id // empty')
ENROLLMENT_JWT=$(echo "$IDENTITY_RESP" | jq -r '.enrollment.ott.jwt // empty')

[ -n "$IDENTITY_ID" ] || error "No se pudo crear la identidad Ziti: $(echo "$IDENTITY_RESP" | jq -r '.message // .')"
success "Identidad creada: ID=$IDENTITY_ID"

# Guardar JWT temporal (solo para enrollment)
echo "$ENROLLMENT_JWT" > /tmp/talos-node-enrollment.jwt
info "JWT de enrollment guardado en /tmp/talos-node-enrollment.jwt"

# ── PASO 3: Cifrar identidad con KMS ─────────────────────────────────────────
info "Cifrando identidad con GCP KMS: $KMS_KEY"

# El JWT de enrollment es lo que se cifra — la System Extension lo usará
# para hacer enrollment al boot y obtener la identidad completa
ENCRYPTED_B64=$(echo -n "$ENROLLMENT_JWT" | \
    gcloud kms encrypt \
        --key="$KMS_KEY" \
        --plaintext-file=- \
        --ciphertext-file=- \
        --project="$GCP_PROJECT_ID" 2>/dev/null | base64 | tr -d '\n')

success "Identidad cifrada con KMS ✅"

# ── PASO 4: Generar patch para MachineConfig ─────────────────────────────────
info "Generando patch para MachineConfig Talos..."

cat > "${OUTPUT_DIR}/ziti-identity-patch.yaml" <<PATCH
# cluster-api/ziti-identity-patches/ziti-identity-patch.yaml
# Patch para TalosControlPlane y TalosConfigTemplate
# Inyecta la identidad Ziti cifrada con KMS GCP
# La Ziti System Extension la descifra al boot usando la SA del nodo
#
# IMPORTANTE: Este fichero contiene un secreto cifrado. NO incluir en git.
# Añadido a .gitignore automáticamente.
#
# Uso: envsubst no necesario — el valor está pre-cifrado

- op: add
  path: /machine/files
  value:
    - path: /etc/ziti/identity-encrypted.jwt.b64
      content: |
        ${ENCRYPTED_B64}
      permissions: "0600"
      op: create
    - path: /etc/ziti/kms-key
      content: "${KMS_KEY}"
      permissions: "0600"
      op: create
PATCH

# Añadir al .gitignore
if ! grep -q "ziti-identity-patches" .gitignore 2>/dev/null; then
    echo "cluster-api/ziti-identity-patches/" >> .gitignore
    info "Añadido cluster-api/ziti-identity-patches/ a .gitignore"
fi

success "Patch generado: ${OUTPUT_DIR}/ziti-identity-patch.yaml ✅"

# ── PASO 5: Instrucciones para aplicar ───────────────────────────────────────
echo -e "\n${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${BOLD}${GREEN}  ✅ Identidad Ziti generada y cifrada${NC}"
echo -e "${BOLD}${GREEN}═══════════════════════════════════════════════════════════${NC}\n"
echo -e "  ${BOLD}Para aplicar el patch al TalosControlPlane:${NC}"
echo ""
echo -e "  export KUBECONFIG=~/.kube/blueupalm-mgmt.yaml"
echo ""
echo -e "  # Aplicar patch al Control Plane:"
echo -e "  kubectl patch taloscontrolplane bc-workload-control-plane \\"
echo -e "    --type=json \\"
echo -e "    --patch=\"\$(cat ${OUTPUT_DIR}/ziti-identity-patch.yaml)\""
echo ""
echo -e "  # Aplicar patch a los Workers:"
echo -e "  kubectl patch talosconfigtemplate bc-workload-workers \\"
echo -e "    --type=json \\"
echo -e "    --patch=\"\$(cat ${OUTPUT_DIR}/ziti-identity-patch.yaml)\""
echo ""
echo -e "  ${BOLD}⚠️  Después del patch, los nodos se reinician automáticamente${NC}"
echo -e "  ${BOLD}   (rolling upgrade gestionado por CACPT)${NC}"
echo ""
