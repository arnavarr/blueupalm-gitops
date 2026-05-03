# talos-extensions/ziti-tunneler/Dockerfile
# Build multi-stage: descarga el binario oficial ziti de la release de GitHub
# y lo empaqueta como Talos System Extension (squashfs + manifest)
#
# Arquitectura moderna: OpenZiti v1.x distribuye binarios pre-compilados,
# no hace falta compilar desde el código fuente.
#
# Uso local (solo para desarrollo):
#   docker buildx build --platform linux/amd64 -t talos-ziti-ext:dev .
#
# En CI: el workflow genera la imagen OCI final firmada con cosign
# Ver: .github/workflows/talos-ziti-extension.yml

# ── Etapa 1: Descargar binario oficial de la release ─────────────────────────
FROM --platform=linux/amd64 alpine:3.19 AS downloader

RUN apk add --no-cache curl tar ca-certificates

# Versión del binario Ziti a instalar (tag oficial del repo openziti/ziti)
ARG ZITI_VERSION=v1.6.15

WORKDIR /download

# Descargar el binario pre-compilado para linux/amd64 desde GitHub Releases
RUN curl -fsSL \
    "https://github.com/openziti/ziti/releases/download/${ZITI_VERSION}/ziti-linux-amd64-${ZITI_VERSION#v}.tar.gz" \
    -o ziti.tar.gz \
  && tar -xzf ziti.tar.gz \
  && chmod +x ziti \
  && ./ziti --version

# ── Etapa 2: Empaquetar como Talos Extension ─────────────────────────────────
FROM scratch AS extension

# Binario oficial OpenZiti
COPY --from=downloader /download/ziti /usr/local/bin/ziti-edge-tunnel

# Manifest de la extensión (leído por el Talos imager)
COPY manifest.yaml /

LABEL org.opencontainers.image.title="ziti-edge-tunneler"
LABEL org.opencontainers.image.description="OpenZiti Edge Tunnel for Talos Linux"
LABEL org.opencontainers.image.vendor="BlueUP Engineering"
LABEL org.opencontainers.image.source="https://github.com/arnavarr/blueupalm-gitops"
