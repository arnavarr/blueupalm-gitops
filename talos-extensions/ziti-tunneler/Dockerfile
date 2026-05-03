# talos-extensions/ziti-tunneler/Dockerfile
# Empaqueta el binario oficial OpenZiti como Talos System Extension
#
# Estrategia: descarga release pre-compilado de GitHub (más rápido que compilar)
# Versión: v1.6.15+ (openziti/ziti)

FROM --platform=linux/amd64 alpine:3.19 AS downloader

# Instalar dependencias y bash
RUN apk add --no-cache curl tar ca-certificates bash

# Cambiar el shell por defecto a bash para este stage
SHELL ["/bin/bash", "-c"]

# Declarar ARG DENTRO del stage (obligatorio en Docker multi-stage)
ARG ZITI_VERSION=v1.6.15

WORKDIR /download

# Descargar, extraer y verificar el binario oficial
# La URL de release usa la versión SIN 'v': ziti-linux-amd64-1.6.15.tar.gz
RUN set -ex \
 && ZITI_VER="${ZITI_VERSION#v}" \
 && URL="https://github.com/openziti/ziti/releases/download/v${ZITI_VER}/ziti-linux-amd64-${ZITI_VER}.tar.gz" \
 && echo "Downloading: ${URL}" \
 && curl -fsSL "${URL}" -o ziti.tar.gz \
 && tar -xzf ziti.tar.gz \
 && ls -la \
 && chmod +x ziti \
 && ./ziti --version

# ── Etapa final: imagen OCI vacía con solo el binario + manifest ──────────────
FROM scratch AS extension

COPY --from=downloader /download/ziti /usr/local/bin/ziti-edge-tunnel
COPY manifest.yaml /

LABEL org.opencontainers.image.title="ziti-edge-tunneler"
LABEL org.opencontainers.image.description="OpenZiti Edge Tunnel for Talos Linux"
LABEL org.opencontainers.image.vendor="BlueUP Engineering"
LABEL org.opencontainers.image.source="https://github.com/arnavarr/blueupalm-gitops"
