# talos-extensions/ziti-tunneler/Dockerfile
# Empaqueta el binario oficial OpenZiti como Talos System Extension
#
# NOTA: El binario oficial de Ziti está linkado dinámicamente contra glibc.
# Por eso usamos debian:slim (glibc) en vez de alpine (musl).

FROM --platform=linux/amd64 debian:bookworm-slim AS downloader

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/*

ARG ZITI_VERSION=1.6.15

WORKDIR /download

RUN curl -fsSL \
    "https://github.com/openziti/ziti/releases/download/v${ZITI_VERSION}/ziti-linux-amd64-${ZITI_VERSION}.tar.gz" \
    -o ziti.tar.gz \
  && tar -xzf ziti.tar.gz \
  && chmod +x ziti \
  && ./ziti --version

# ── Etapa final: imagen OCI con el binario + manifest ────────────────────────
# Necesitamos las libs glibc para que el binario funcione en Talos
FROM debian:bookworm-slim AS extension

COPY --from=downloader /download/ziti /usr/local/bin/ziti-edge-tunnel
COPY manifest.yaml /

LABEL org.opencontainers.image.title="ziti-edge-tunneler"
LABEL org.opencontainers.image.description="OpenZiti Edge Tunnel for Talos Linux"
LABEL org.opencontainers.image.vendor="BlueUP Engineering"
LABEL org.opencontainers.image.source="https://github.com/arnavarr/blueupalm-gitops"
