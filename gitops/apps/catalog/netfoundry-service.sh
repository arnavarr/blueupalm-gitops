#!/usr/bin/env bash
# netfoundry-service.sh — Crea el Dark Service catalog.bc.internal en NetFoundry
# Ejecutar UNA sola vez tras desplegar el nginx en K8s.
# Prerrequisito: kubectl port-forward o acceso al cluster activo.
set -euo pipefail

CREDS_FILE="${CREDS_FILE:-/Volumes/DATOS/source/ziti-tunneler-macos/credentials_netfoundry.json}"
NF_AUTH_URL="https://netfoundry-production-xfjiye.auth.us-east-1.amazoncognito.com/oauth2/token"
NF_API="https://gateway.production.netfoundry.io/core/v2"
NETWORK_ID="b82f4619-7b7c-4bad-8259-8bd1128d715a"

CLIENT_ID=$(jq -r '.clientId' "$CREDS_FILE")
CLIENT_SECRET=$(jq -r '.password' "$CREDS_FILE")

echo "🔑 Obteniendo token NetFoundry..."
TOKEN=$(curl -s -X POST "$NF_AUTH_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials&client_id=${CLIENT_ID}&client_secret=${CLIENT_SECRET}" \
  | jq -r '.access_token')

if [ -z "$TOKEN" ] || [ "$TOKEN" = "null" ]; then
  echo "❌ Error obteniendo token NetFoundry"
  exit 1
fi
echo "✅ Token OK"

# Dirección del Service K8s dentro del cluster
# El Edge Router de NetFoundry en el cluster debe poder resolver esto
CATALOG_K8S_HOST="zta-catalog-nginx.catalog.svc.cluster.local"
CATALOG_K8S_PORT=80

echo "📦 Creando Dark Service catalog.bc.internal → ${CATALOG_K8S_HOST}:${CATALOG_K8S_PORT}..."
SERVICE_RESULT=$(curl -s -X POST "${NF_API}/services" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"networkId\": \"${NETWORK_ID}\",
    \"name\": \"catalog.bc.internal\",
    \"modelType\": \"TunnelerToEndpoint\",
    \"encryptionRequired\": true,
    \"attributes\": [\"#catalog-service\"],
    \"model\": {
      \"clientIngress\": {
        \"host\": \"catalog.bc.internal\",
        \"port\": 80
      },
      \"serverEgress\": {
        \"protocol\": \"tcp\",
        \"host\": \"${CATALOG_K8S_HOST}\",
        \"port\": ${CATALOG_K8S_PORT}
      },
      \"edgeRouterAttributes\": [\"#all\"],
      \"bindEndpointAttributes\": [\"#edge-router\"]
    }
  }")

SERVICE_ID=$(echo "$SERVICE_RESULT" | jq -r '.id // empty')
if [ -z "$SERVICE_ID" ]; then
  echo "⚠️  Respuesta del API:"
  echo "$SERVICE_RESULT" | jq .
  exit 1
fi
echo "✅ Servicio creado: ID=$SERVICE_ID"

# Crear AppWAN Policy: accesible por #zta-clients y #desktop-clients
echo "📋 Creando AppWAN Policy para #zta-clients y #desktop-clients..."
curl -s -X POST "${NF_API}/app-wans" \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{
    \"networkId\": \"${NETWORK_ID}\",
    \"name\": \"catalog-access-policy\",
    \"endpointAttributes\": [\"#zta-clients\", \"#desktop-clients\"],
    \"serviceAttributes\": [\"#catalog-service\"]
  }" | jq '{id, name, endpointAttributes, serviceAttributes}'

echo ""
echo "✅ Dark Service catalog.bc.internal configurado en NetFoundry"
echo "   Clientes con atributos #zta-clients o #desktop-clients pueden acceder a:"
echo "   http://catalog.bc.internal/catalog.yaml"
