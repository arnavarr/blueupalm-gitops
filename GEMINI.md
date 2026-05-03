# BlueUPALM — Infraestructura y Operaciones (Runbook)

Este archivo contiene mandatos técnicos y procedimientos de resolución de problemas para el mantenimiento de la plataforma BlueUPALM.

**Stack actual:** Talos Linux v1.7.6 + CAPI/CAPG + Zero-Trust (OpenZiti/NetFoundry)  
**Arquitectura:** `docs/architecture/talos-sovereign-stack.md`

---

## 🚀 Despliegue y Recuperación

### 1. Sincronización de Credenciales CAPG
Si Terraform regenera el archivo `bootstrap/capg-credentials.json` (por rotación de claves o recreación de la SA), el Management Cluster debe ser actualizado manualmente:

```bash
# Actualizar el secreto en el namespace de CAPG
kubectl create secret generic capg-manager-bootstrap-credentials \
    -n capg-system \
    --from-file=credentials.json=bootstrap/capg-credentials.json \
    --dry-run=client -o yaml | kubectl apply -f -

# Reiniciar el controlador para cargar las nuevas credenciales
kubectl delete pod -n capg-system -l control-plane=capg-controller-manager
```

### 2. Clusters Bloqueados en fase "Deleting"
Si un cluster o máquina de CAPI se queda atascado en estado de eliminación, forzar la limpieza de *finalizers*:

```bash
# Para el cluster principal
kubectl patch cluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl patch gcpcluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge

# Para máquinas individuales (si es necesario)
kubectl patch gcpmachine <nombre-maquina> -p '{"metadata":{"finalizers":null}}' --type=merge
```

### 3. Imagen GCE Talos
El Workload Cluster usa la imagen oficial de Talos Linux (familia `talos-linux`), NO una imagen custom.
- **Si el despliegue falla con Error 404 (Image not found):** El paso 4 de `setup_all.sh` la registra automáticamente.
- **Para registrar manualmente:**
```bash
TALOS_VERSION=v1.7.6
curl -fsSL "https://github.com/siderolabs/talos/releases/download/${TALOS_VERSION}/gcp-amd64.tar.gz" \
  -o /tmp/talos-gce.tar.gz
gsutil cp /tmp/talos-gce.tar.gz gs://${GCP_PROJECT_ID}-talos-images/talos-${TALOS_VERSION}.tar.gz
gcloud compute images create "talos-${TALOS_VERSION//./-}-gce-amd64" \
  --source-uri="gs://${GCP_PROJECT_ID}-talos-images/talos-${TALOS_VERSION}.tar.gz" \
  --project="$GCP_PROJECT_ID" --family=talos-linux
```

---

## 🖥️ Operativa con talosctl (reemplaza SSH)

> **Talos Linux no tiene SSH ni shell interactiva.** Toda operación se realiza vía `talosctl` (gRPC mTLS).
> En Fase 4 (Zero-Trust activo), el endpoint es `talos-api.bc.internal` (Ziti dark service).

### Comandos operativos equivalentes

| Operación anterior (SSH) | Equivalente Talos |
|---|---|
| `ssh node journalctl -u kubelet` | `talosctl logs kubelet --nodes <IP>` |
| `ssh node dmesg` | `talosctl dmesg --nodes <IP>` |
| `ssh node systemctl restart containerd` | `talosctl service containerd restart --nodes <IP>` |
| `ssh node tcpdump -i eth0` | `talosctl pcap --nodes <IP> \| tcpdump -r -` |
| `ssh node cat /var/log/audit.log` | `talosctl read /var/log/kube-apiserver-audit.log --nodes <IP>` |
| `ssh node reboot` | `talosctl reboot --nodes <IP>` |
| Ver versión OS | `talosctl version --nodes <IP>` |
| Estado de salud del nodo | `talosctl health --nodes <IP>` |
| Listar servicios | `talosctl services --nodes <IP>` |

### Verificar Ziti Extension en nodo

```bash
# Verificar que el Ziti Edge Tunneler está activo (Fase 4)
talosctl service ziti-edge-tunneler status --nodes talos-api.bc.internal

# Ver logs del tunneler
talosctl logs ziti-edge-tunneler --nodes talos-api.bc.internal
```

### Upgrade de nodos Talos (rolling)

```bash
# El upgrade es gestionado por CACPT — solo actualizar la versión en TalosControlPlane
kubectl patch taloscontrolplane bc-workload-control-plane \
  --type=merge \
  -p '{"spec":{"version":"v1.29.7","controlPlaneConfig":{"controlplane":{"talosVersion":"v1.7.7"}}}}'

# CACPT hace rolling upgrade automático (un nodo a la vez)
# Monitorizar:
kubectl get taloscontrolplane bc-workload-control-plane -w
```

---

## 🛡️ Estándares de Hardening (DORA/PBC-FT)

- **Networking:** Los Load Balancers del API Server son de tipo `Internal` (especificado en `cluster-api/cluster.yaml`). En Fase 4, el acceso es exclusivamente via Ziti overlay.
- **OS:** Talos Linux — sistema de archivos de solo lectura, sin SSH, sin shell. Inmutabilidad verificable criptográficamente.
- **Auditoría:** La política de auditoría está en el `MachineConfig` (`cluster-api/talos-machineconfig-controlplane.yaml`) — forma parte de la imagen firmada, no de un script post-instalación.
- **DNS:** La zona de Cloud DNS tiene activado `prevent_destroy = true` en Terraform para proteger el dominio `navarro-bores.com`.
- **KMS:** Las identidades Ziti de los nodos están cifradas con GCP KMS (`ziti-machineconfig-identity`). Los backups de DR están cifrados con `dr-backup` key.

---

## 🔐 Fase 4 — Procedimientos Zero-Trust

### Secuencia de activación (CRÍTICA — no alterar el orden)

```bash
# 1. Verificar que la Ziti System Extension está activa en los nodos
talosctl service ziti-edge-tunneler status --nodes <CP_IP>

# 2. Cifrar identidad Ziti e inyectar en MachineConfig
bash scripts/fase4-inject-ziti-identity.sh

# 3. Crear Dark Services NetFoundry + verificar acceso Ziti
bash scripts/fase4-setup-ziti-dark-services.sh

# 4. SOLO si el paso 3 verificó acceso OK: activar firewall
bash scripts/fase4-enable-zero-trust-firewall.sh
```

### Rollback de emergencia (si se pierde acceso)

```bash
# Desactivar el firewall desde GCP Console o CLI (sin necesitar acceso al cluster)
gcloud compute firewall-rules update bc-workload-deny-cp-direct \
  --disabled \
  --project=${GCP_PROJECT_ID}

# El acceso directo se restaura inmediatamente
```

---

## 💾 Disaster Recovery (DR)

### Backup manual

```bash
export GCP_PROJECT_ID=homelab-466309
export KUBECONFIG=~/.kube/blueupalm-workload.yaml

# Backup completo: etcd + Talos PKI + SPIRE CA
bash scripts/dr-backup.sh
```

### Restore en región secundaria

```bash
# Ver: docs/architecture/talos-sovereign-stack.md — Sección 7 (DR)
# Flujo: Terraform → Talos boot → talosctl bootstrap --recover-from GCS → Flux reconcilia
```

### Verificar estado de backups en GCS

```bash
DR_BUCKET="${GCP_PROJECT_ID}-blueupalm-dr"
echo "=== Último snapshot etcd ==="
gsutil cat gs://${DR_BUCKET}/etcd/latest
echo ""
echo "=== Talos secrets ==="
gsutil ls gs://${DR_BUCKET}/talos-secrets/
echo ""
echo "=== SPIRE CA ==="
gsutil cat gs://${DR_BUCKET}/spire/latest
```

---

## 📋 Checklist de Arranque de Sesión

```bash
# 0. Verificar que OrbStack está corriendo (reemplaza Docker Desktop)
orb status 2>/dev/null || open -a OrbStack

# 1. Exportar variables
export GCP_PROJECT_ID=homelab-466309
export FLUX_GITHUB_TOKEN=$(gh auth token)
export LETSENCRYPT_EMAIL=arturo@navarro-bores.com
export NF_CLIENT_ID=$(gcloud secrets versions access latest --secret=blueupalm-nf-client-id --project=$GCP_PROJECT_ID)
export NF_CLIENT_SECRET=$(gcloud secrets versions access latest --secret=blueupalm-nf-client-secret --project=$GCP_PROJECT_ID)

# 2. Verificar imagen Talos en GCE
gcloud compute images list --project=$GCP_PROJECT_ID --filter="family:talos-linux"

# 3. Setup completo
cd /Volumes/DATOS/source/infra
bash setup_all.sh

# 4. Una vez cluster Ready — verificar Flux
export KUBECONFIG=~/.kube/blueupalm-workload.yaml
flux get kustomizations -A
kubectl get pods -A

# 5. AL FINALIZAR SIEMPRE
bash hibernate.sh
```
