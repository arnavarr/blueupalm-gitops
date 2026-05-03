# talos-extensions/ziti-tunneler/Dockerfile
# Empaqueta el binario oficial OpenZiti como Talos System Extension

FROM --platform=linux/amd64 alpine:3.19 AS downloader

RUN apk add --no-cache curl tar ca-certificates

ARG ZITI_VERSION=1.6.15

WORKDIR /download

# Descargar el binario pre-compilado para linux/amd64 desde GitHub Releases
# ARG ZITI_VERSION NO incluye el prefijo 'v' para simplificar la URL
RUN curl -fsSL \
    "https://github.com/openziti/ziti/releases/download/v${ZITI_VERSION}/ziti-linux-amd64-${ZITI_VERSION}.tar.gz" \
    -o ziti.tar.gz \
  && tar -xzf ziti.tar.gz \
  && chmod +x ziti \
  && ./ziti --version

# ── Etapa final ───────────────────────────────────────────────────────────────
FROM scratch AS extension

COPY --from=downloader /download/ziti /usr/local/bin/ziti-edge-tunnel
COPY manifest.yaml /

LABEL org.opencontainers.image.title="ziti-edge-tunneler"
LABEL org.opencontainers.image.description="OpenZiti Edge Tunnel for Talos Linux"
LABEL org.opencontainers.image.vendor="BlueUP Engineering"
LABEL org.opencontainers.image.source="https://github.com/arnavarr/blueupalm-gitops"
