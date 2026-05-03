# talos-extensions/ziti-tunneler/Dockerfile
# Build multi-stage: compila el binario ziti-edge-tunnel para linux/amd64
# y lo empaqueta como Talos System Extension (squashfs + manifest)
#
# Uso local (solo para desarrollo):
#   docker buildx build --platform linux/amd64 -t talos-ziti-ext:dev .
#
# En CI: el imager de Talos genera la imagen OCI final firmada con cosign
# Ver: .github/workflows/talos-ziti-extension.yml

# ── Etapa 1: Compilar ziti-edge-tunnel ───────────────────────────────────────
FROM --platform=linux/amd64 golang:1.22-alpine AS builder

RUN apk add --no-cache \
    gcc musl-dev libpcap-dev iproute2-dev \
    git curl ca-certificates

# Versión del Ziti SDK a compilar
ARG ZITI_VERSION=v0.22.28

WORKDIR /src
RUN git clone --depth 1 --branch ${ZITI_VERSION} \
    https://github.com/openziti/ziti.git .

# Compilar el tunneler estático para linux/amd64
RUN CGO_ENABLED=1 GOOS=linux GOARCH=amd64 \
    go build -ldflags="-s -w -extldflags=-static" \
    -o /out/ziti-edge-tunnel \
    ./ziti-tunnel/cmd/ziti-tunnel

# ── Etapa 2: Empaquetar como Talos Extension ─────────────────────────────────
FROM scratch AS extension

# Binario compilado
COPY --from=builder /out/ziti-edge-tunnel /usr/local/bin/ziti-edge-tunnel

# Manifest de la extensión
COPY manifest.yaml /

# Script de arranque (systemd unit generado por Talos automáticamente)
# El tunneler se inicia con: ziti-edge-tunnel tun --identity /etc/ziti/identity.json
LABEL org.opencontainers.image.title="ziti-edge-tunneler"
LABEL org.opencontainers.image.description="OpenZiti Edge Tunneler for Talos Linux"
LABEL org.opencontainers.image.vendor="BlueUP Engineering"
