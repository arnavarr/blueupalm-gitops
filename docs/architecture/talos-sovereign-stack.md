# BlueUPALM — Sovereign Hardened Stack
## Arquitectura Talos Linux + CAPI/CAPG + Zero Trust

> **Versión**: 1.0 | **Fecha**: 2026-05-03  
> **Estado**: Aprobado — Pendiente implementación por fases  
> **Contexto**: Resolución de INC-001/002 del post-mortem 2026-05-03 y preparación para producción bancaria (DORA/PBC-FT)

---

## 1. Visión General

La arquitectura actual (Ubuntu + kubeadm + kind en Mac) ha demostrado ser frágil en el proceso de bootstrap del cluster CAPI/CAPG. Este documento define el diseño objetivo que resuelve estos problemas de raíz mediante Talos Linux, manteniendo la portabilidad multi-cloud de CAPI y añadiendo un modelo Zero Trust para el plano de control.

### Principios Rectores

1. **Infraestructura como código declarativo**: Un `MachineConfig` YAML define completamente un nodo. Cero scripts bash, cero cloud-init, cero SSH.
2. **Inmutabilidad**: El sistema de archivos de los nodos es de solo lectura. No hay mecanismo de modificación en caliente.
3. **Zero Trust desde el primer boot**: El plano de control (Talos API :50000, kube-apiserver :6443) es invisible en la red pública desde el primer segundo de vida del nodo.
4. **Portabilidad verificable**: El mismo `MachineConfig` funciona en local (QEMU), GCP y AWS. Solo cambian los recursos de infraestructura del provider CAPI.

---

## 2. Stack Tecnológico

### Antes (kubeadm)
```
Management:  kind (Docker Desktop local)     ← INC-001: dependencia Docker Desktop
Bootstrap:   KubeadmControlPlane             ← INC-002: timeouts de kubeadm
Workers:     KubeadmConfigTemplate           ← scripts bash + cloud-init
OS:          Ubuntu 22.04 custom (Packer)    ← imagen GCE custom: mantenimiento manual
```

### Objetivo (Talos)
```
Management:  talosctl cluster create (QEMU/OrbStack)  ← sin Docker Desktop
Bootstrap:   CACPT (TalosControlPlane)                ← bootstrap <2 min, determinístico
Workers:     CABPT (TalosConfigTemplate)               ← MachineConfig declarativo
OS:          Talos Linux v1.7.x (imagen oficial GCE)  ← sin mantenimiento de imagen
```

### Providers CAPI requeridos
```bash
clusterctl init \
  --infrastructure gcp:v1.7.0 \          # CAPG — sin cambios
  --core cluster-api:v1.7.0 \            # sin cambios
  --bootstrap talos:v0.5.0 \             # CABPT — nuevo
  --control-plane talos:v0.5.0           # CACPT — nuevo (reemplaza kubeadm)
```

---

## 3. MachineConfig de Referencia

### Control Plane
```yaml
# cluster-api/talos-machineconfig-controlplane.yaml
apiVersion: v1alpha1
kind: MachineConfig
machine:
  type: controlplane
  kubelet:
    extraArgs:
      cloud-provider: external          # GCP CCM / AWS CCM según provider
  network:
    interfaces:
      - interface: eth0
        dhcp: true
  install:
    disk: /dev/sda                      # GCP: /dev/sda | AWS: /dev/xvda|/dev/nvme0n1
    image: ghcr.io/siderolabs/installer:v1.7.6
    extensions:
      - image: ghcr.io/siderolabs/gvisor:20240101.0
      - image: ghcr.io/siderolabs/kata-containers:3.4.0    # nested virt requerida en GCE
      - image: ghcr.io/blueup/talos-ziti-extension:v0.1.0  # [Fase 4] custom build
  sysctls:
    net.ipv4.ip_forward: "1"
    net.bridge.bridge-nf-call-iptables: "1"

cluster:
  network:
    podSubnets:
      - 10.1.0.0/16
    serviceSubnets:
      - 10.2.0.0/20
    cni:
      name: none                        # Cilium lo instala Flux (no CNI nativo)
  etcd:
    advertisedSubnets:
      - 10.0.0.0/24                    # Subnet interna GCP
  apiServer:
    listenAddress: 127.0.0.1           # [Fase 4] bind localhost — solo accesible vía Ziti
    extraArgs:
      audit-log-path: /var/log/kube-apiserver-audit.log
      audit-log-maxage: "30"
      audit-log-maxbackup: "3"
      audit-log-maxsize: "100"
      # OIDC: no en bootstrap — se añade post-deploy cuando Keycloak/Dex están activos
    certSANs:
      - k8s-api.bc.internal            # [Fase 4] SAN para acceso vía Ziti overlay
  inlineManifests:
    - name: audit-policy
      contents: |
        apiVersion: audit.k8s.io/v1
        kind: Policy
        rules:
        - level: RequestResponse
          resources:
          - group: ""
            resources: ["secrets"]
        - level: Metadata
          verbs: ["delete","create","update","patch"]
        - level: None
          verbs: ["get","list","watch"]
          resources:
          - group: ""
            resources: ["events","nodes","pods"]
```

### Workers (Ceph OSD)
```yaml
# cluster-api/talos-machineconfig-worker.yaml
apiVersion: v1alpha1
kind: MachineConfig
machine:
  type: worker
  kubelet:
    extraArgs:
      cloud-provider: external
      node-labels: "role=worker,ceph-osd=true"
  install:
    disk: /dev/sda
    image: ghcr.io/siderolabs/installer:v1.7.6
    extensions:
      - image: ghcr.io/siderolabs/gvisor:20240101.0
  disks:
    - device: /dev/sdb                 # Disco de datos GCE (200GB pd-standard)
      partitions: []                   # Sin particiones — Rook-Ceph lo gestiona en bruto
  # Módulo kernel rbd incluido en Talos v1.7 base
  # drbd (replicación síncrona): requiere extensión si se activa multi-site
```

### Portabilidad: única diferencia entre GCP y AWS

| Parámetro | GCP | AWS |
|---|---|---|
| `machine.install.disk` | `/dev/sda` | `/dev/xvda` o `/dev/nvme0n1` |
| `cluster.etcd.advertisedSubnets` | `10.0.0.0/24` (VPC GCP) | Subnet privada AWS |
| Imagen Talos | GCE raw image oficial | AMI oficial de Talos |
| `infrastructureTemplate.kind` | `GCPMachineTemplate` | `AWSMachineTemplate` |

Todo lo demás (`cluster.network`, extensions, audit policy, apiServer config) es **binariamente idéntico**.

---

## 4. Manifiestos CAPI (Talos)

### TalosControlPlane (reemplaza KubeadmControlPlane)
```yaml
# cluster-api/control-plane.yaml
apiVersion: controlplane.cluster.x-k8s.io/v1alpha3
kind: TalosControlPlane
metadata:
  name: bc-workload-control-plane
  namespace: default
spec:
  version: v1.29.6
  replicas: 1                          # HA: 3 en producción bancaria real
  infrastructureTemplate:
    apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
    kind: GCPMachineTemplate
    name: bc-workload-control-plane    # Sin cambios respecto al actual
  controlPlaneConfig:
    controlplane:
      generateType: controlplane       # Talos genera PKI propio — no kubeadm
      talosVersion: v1.7.6
      configPatches:
        - op: replace
          path: /machine/install/disk
          value: /dev/sda
        - op: add
          path: /machine/install/extensions
          value:
            - image: ghcr.io/siderolabs/gvisor:20240101.0
        - op: add
          path: /cluster/apiServer/extraArgs
          value:
            audit-log-path: /var/log/kube-apiserver-audit.log
---
# GCPMachineTemplate — sin cambios respecto al actual
apiVersion: infrastructure.cluster.x-k8s.io/v1beta1
kind: GCPMachineTemplate
metadata:
  name: bc-workload-control-plane
  namespace: default
spec:
  template:
    spec:
      subnet: "blueupalm-subnet-${GCP_REGION}"
      # Talos usa imagen oficial GCE — elimina 03-build-gce-image.sh
      image: "projects/talos-dev/global/images/talos-v1-7-6-gce-amd64"
      instanceType: "e2-standard-4"
      rootDeviceSize: 100
      rootDeviceType: "pd-ssd"
      enableNestedVirtualization: true  # Requerido para Kata Containers
      serviceAccounts:
        email: "${NODES_SA_EMAIL}"
        scopes:
          - "https://www.googleapis.com/auth/cloud-platform"
      additionalLabels:
        role: control-plane
        project: blueupalm
      additionalNetworkTags:
        - "bc-workload-node"
```

### TalosConfigTemplate (reemplaza KubeadmConfigTemplate en workers)
```yaml
# cluster-api/workers.yaml
apiVersion: bootstrap.cluster.x-k8s.io/v1alpha3
kind: TalosConfigTemplate
metadata:
  name: bc-workload-workers
  namespace: default
spec:
  template:
    spec:
      generateType: worker
      talosVersion: v1.7.6
      configPatches:
        - op: replace
          path: /machine/install/disk
          value: /dev/sda
        - op: add
          path: /machine/disks
          value:
            - device: /dev/sdb
              partitions: []
```

---

## 5. Zero-Trust Control Plane (Fase 4)

### Arquitectura objetivo

```
Administrador (Mac)
  │  talosctl / kubectl
  │  con identidad Ziti activa (OrbStack/tunneler)
  │
  ▼ Ziti Overlay (NetFoundry SaaS)
  │
  ├─► Dark Service: talos-api.bc.internal:50000
  │     └─► Talos API (gRPC mTLS)
  │
  └─► Dark Service: k8s-api.bc.internal:6443
        └─► kube-apiserver (solo localhost en el nodo)
```

### Identidad Ziti Bootstrap — sin chicken-and-egg

El truco es que la identidad Ziti **se inyecta en el MachineConfig** antes del primer boot, cifrada con GCP KMS. La System Extension de Ziti (corriendo antes de containerd) la desencripta usando las credenciales de la Service Account de la VM.

```yaml
# Fragmento MachineConfig — Fase 4
machine:
  files:
    - path: /etc/ziti/identity-encrypted.json
      content: |
        # Identidad Ziti cifrada con KMS GCP
        # Desencriptada al boot por la System Extension usando SA de la VM
        ${ZITI_IDENTITY_KMS_ENCRYPTED_B64}
      permissions: "0600"
      op: create
  install:
    extensions:
      - image: ghcr.io/blueup/talos-ziti-extension:v0.1.0  # custom build
```

### Build de la System Extension (pipeline CI)
```bash
# .github/workflows/talos-ziti-extension.yml
# Requiere: Talos Extensions SDK, Ziti Edge SDK (C/Rust), imager de Talos

# 1. Compilar el binario ziti-edge-tunnel para linux/amd64
# 2. Empaquetar como Talos System Extension (squashfs)
# 3. Publicar en ghcr.io/blueup/talos-ziti-extension
# 4. Firmar con cosign (supply chain verification)

docker run --rm ghcr.io/siderolabs/imager:v1.7.6 \
  --system-extension-image ghcr.io/blueup/talos-ziti-extension:v0.1.0 \
  output --output talos-ziti.raw gcp
```

### Dark Services en NetFoundry
```bash
# Ejecutar post-cluster-ready, pre-firewall-hardening
nf create service --name "talos-api-bc" \
  --address "talos-api.bc.internal" --port 50000 --scheme tcp

nf create service --name "k8s-api-bc" \
  --address "k8s-api.bc.internal" --port 6443 --scheme tcp

# AppWAN: solo identidades de administrador y CAPI bootstrap
nf create app-wan --name "bc-control-plane-access" \
  --services "talos-api-bc,k8s-api-bc" \
  --endpoints "admin-identity,capi-bootstrap-identity"
```

### Firewall GCP — bloqueo de acceso directo (último paso)
```hcl
# terraform/main.tf — activar en Fase 4
resource "google_compute_firewall" "deny_controlplane_external" {
  name      = "blueupalm-deny-cp-external"
  network   = google_compute_network.vpc.name
  direction = "INGRESS"
  priority  = 800

  deny {
    protocol = "tcp"
    ports    = ["50000", "6443"]
  }
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["bc-workload-node"]
}
```

---

## 6. Rook-Ceph en Talos

### Configuración de disco
El disco de datos (`/dev/sdb`) se declara en el MachineConfig sin particiones.
Rook-Ceph lo descubre y lo gestiona en bruto (OSD sobre block device).

```yaml
machine:
  disks:
    - device: /dev/sdb    # 200GB pd-standard en GCE
      partitions: []      # Rook gestiona el disco completo
```

### Módulos kernel requeridos
| Módulo | Disponibilidad Talos v1.7 | Notas |
|---|---|---|
| `rbd` | ✅ Incluido en imagen base | Necesario para PVCs RBD |
| `ceph` | ✅ Incluido en imagen base | Librería userspace en pods Rook |
| `drbd` | ❌ Requiere extensión `siderolabs/drbd` | Solo si se activa replicación síncrona multi-site |

Para la arquitectura actual (single-region, Ceph nativo), **no se requiere la extensión drbd**.

---

## 7. Estrategia de DR por Tiers

### Principio
El snapshot de etcd contiene **solo metadatos K8s** (specs de pods, services, configmaps). Los datos de aplicación (PostgreSQL, Qdrant, logs) viven en PVCs de Ceph. El RTO depende de qué tier se necesita recuperar primero.

### Tiers de Datos

| Tier | Datos | Tecnología | RTO Objetivo | RPO |
|---|---|---|---|---|
| **1 — Regulado** | AML Audit Trail, ProvisioningRequests, DORA events | CloudSQL PostgreSQL (reemplaza Ceph para estos datos) | **<2 min** (PITR) | <5s |
| **2 — Operacional** | Qdrant vectores, NATS JetStream state | Rook-Ceph + Velero snapshots GCS | ~15-20 min | ~15 min |
| **3 — Observabilidad** | Loki logs, Prometheus metrics | Rook-Ceph (sacrificable en DR) | Best effort | N/A |

### Flujo de DR (<10 min para Tier 1)

```bash
# T+0: Desastre confirmado en europe-west1

# T+1min: Terraform crea recursos IaaS en europe-west4
terraform workspace select dr-europe-west4
terraform apply -var="gcp_region=europe-west4" -auto-approve

# T+2min: VMs Talos bootean, MachineConfig aplicado desde GCS cifrado con KMS
# (la VM descarga el MachineConfig de gs://blueupalm-bootstrap/machineconfig-encrypted.yaml)

# T+3min: Bootstrap etcd desde secrets Talos en GCS
talosctl bootstrap \
  --nodes 10.2.0.11 \
  --recover-from gs://blueupalm-dr/talos-secrets-latest.yaml

# T+5min: Restore snapshot etcd
talosctl etcd snapshot restore \
  --snapshot gs://blueupalm-dr/etcd/snap-$(cat gs://blueupalm-dr/etcd/latest) \
  --nodes 10.2.0.11

# T+6min: Flux reconcilia — plano de control K8s operativo
flux reconcile kustomization infrastructure --with-source

# T+8min: CloudSQL Tier 1 activo vía PITR (servicio gestionado GCP — sobrevive al desastre regional)

# T+10min: Plataforma operativa para datos regulados ✅
# T+20min: Qdrant/NATS restaurados desde Velero ✅
```

### Backup Automático

```yaml
# flux/clusters/bc-workload/observability/etcd-backup-job.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: etcd-backup
  namespace: kube-system
spec:
  schedule: "*/15 * * * *"    # Cada 15 minutos
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: google/cloud-sdk:alpine
            command:
            - sh
            - -c
            - |
              talosctl etcd snapshot /tmp/snap.db
              gsutil cp /tmp/snap.db \
                gs://blueupalm-dr/etcd/snap-$(date +%s).db
              echo $(date +%s) | gsutil cp - gs://blueupalm-dr/etcd/latest
```

### Talos Secrets Backup (PKI del cluster)

```bash
# Ejecutar una sola vez post-bootstrap, guardar en GCS cifrado
talosctl gen secrets --output-file secrets.yaml

gcloud storage cp secrets.yaml \
  gs://blueupalm-dr/talos-secrets-$(date +%Y%m%d).yaml \
  --encryption-key=projects/homelab-466309/locations/global/keyRings/blueupalm/cryptoKeys/dr-key

# En DR: restaurar con misma PKI (mismos certs, misma identidad de cluster)
talosctl gen config bc-workload https://10.2.0.100:6443 \
  --with-secrets secrets.yaml
```

---

## 8. SPIRE en DR (Riesgo No Obvio)

SPIRE tiene su propia PKI (Root CA + Intermediate CAs) que **no está en el snapshot de etcd**. En un desastre total:

1. La Root CA de SPIRE está en un PVC de Ceph (Tier 2 — RTO ~20 min)
2. Mientras SPIRE no está operativo, los workloads con SVID no pueden arrancar

**Mitigación:**
```bash
# Backup de SPIRE Root CA en GCS (separado del backup etcd)
kubectl get secret -n spire spire-server-ca -o yaml | \
  gcloud kms encrypt \
    --key=projects/homelab-466309/locations/global/keyRings/blueupalm/cryptoKeys/dr-key \
    --plaintext-file=- \
    --ciphertext-file=- | \
  gsutil cp - gs://blueupalm-dr/spire/root-ca-$(date +%s).enc
```

---

## 9. Gestión Operativa con talosctl

> **Cambio cultural**: no existe SSH, no existe bash en los nodos. Todo diagnóstico es vía `talosctl`.

### Comandos equivalentes

| Operación SSH/bash anterior | Equivalente Talos |
|---|---|
| `ssh node journalctl -u kubelet` | `talosctl logs kubelet --nodes 10.0.0.11` |
| `ssh node dmesg` | `talosctl dmesg --nodes 10.0.0.11` |
| `ssh node systemctl restart containerd` | `talosctl service containerd restart --nodes 10.0.0.11` |
| `ssh node tcpdump -i eth0` | `talosctl pcap --nodes 10.0.0.11 \| tcpdump -r -` |
| `ssh node cat /etc/kubernetes/audit.log` | `talosctl read /var/log/kube-apiserver-audit.log --nodes 10.0.0.11` |
| `ssh node reboot` | `talosctl reboot --nodes 10.0.0.11` |
| Ver versión del OS | `talosctl version --nodes 10.0.0.11` |

### Actualización del Runbook (GEMINI.md)

El `GEMINI.md` del repositorio debe actualizarse en la Fase 2 para incluir:
- Reemplazar procedimiento de "kubeconfig manual" por `talosctl kubeconfig`
- Reemplazar "Sincronización de credenciales CAPG" (sin cambios — CAPG no cambia)
- Añadir procedimiento de upgrade de nodos Talos (rolling upgrade vía `TalosControlPlane`)

---

## 10. Tabla de Eliminación de Componentes

Al completar todas las fases, los siguientes componentes se eliminan:

| Componente Eliminado | Reemplazado por |
|---|---|
| `bootstrap/01-install-local-deps.sh` (kind, kubeadm) | `talosctl cluster create --provisioner qemu` |
| `bootstrap/03-build-gce-image.sh` (Packer) | Imagen Talos oficial para GCE |
| `cluster-api/control-plane.yaml` (KubeadmControlPlane) | TalosControlPlane |
| `cluster-api/workers.yaml` (KubeadmConfigTemplate) | TalosConfigTemplate |
| Docker Desktop (INC-001) | OrbStack + QEMU |
| Reglas kubeadm timeout (INC-002) | Bootstrap Talos determinístico (<2 min) |
| Acceso SSH a nodos | `talosctl` vía Ziti dark service |
