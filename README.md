# blueupalm-gitops

> Repositorio GitOps de **BlueUPALM** — Infraestructura GCP + Stack CNCF + Despliegues de Aplicación
>
> Gestionado por **Flux CD**. El código fuente de las aplicaciones vive en [`arnavarr/bc`](https://github.com/arnavarr/bc).

## Arquitectura

```
┌──────────────────────────────────┐    CI/CD     ┌──────────────────────────────────┐
│  arnavarr/bc  (Desarrollo)       │  ──────────► │  GHCR (Registro de imágenes)     │
│                                  │  gh actions  │  ghcr.io/arnavarr/bc-*           │
│  ├── edge-security/  (Rust)      │              └──────────────┬───────────────────┘
│  ├── src/            (Python)    │                             │ Flux Image Poll (5m)
│  └── frontend/       (React)     │              ┌──────────────▼───────────────────┐
└──────────────────────────────────┘              │  arnavarr/blueupalm-gitops  ◄─── │
                                                  │  (este repositorio)              │
                                                  │                                  │
                                                  │  Flux CD sincroniza →            │
                                                  │  K8s Workload Cluster GCP        │
                                                  └──────────────────────────────────┘
```

**Stack CNCF desplegado:**
- **Plataforma**: Cluster API + CAPG (GCE VMs en `europe-west1`, no GKE)
- **CNI**: Cilium con WireGuard (cifrado en tránsito)
- **GitOps**: Flux CD (image-reflector + image-automation)
- **Identidad**: Keycloak (humana) + SPIRE (workload SVID)
- **Políticas**: OPA (Rego), NetworkPolicies Cilium L7
- **Red Zero-Trust**: OpenZiti (overlay para CDC on-premise)
- **Messaging**: NATS JetStream 3 réplicas HA (NKey Ed25519, sin TLS propio)
- **Ingress**: Traefik v3 + cert-manager + Let's Encrypt DNS-01
- **Storage**: Rook-Ceph + PostgreSQL + Qdrant + Trino
- **Observabilidad**: kube-prometheus-stack + Loki + Hubble UI
- **Sandboxing**: gVisor (runsc) para workloads de datos bancarios

---

## Estructura del Repositorio

```
blueupalm-gitops/
├── terraform/                    # IaC GCP: VPC, IAM, Secret Manager, Cloud DNS
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── terraform.tfvars.example  # Copiar a terraform.tfvars (gitignored)
│   └── modules/
│       ├── vpc/                  # VPC blueupalm-vpc + subnets + firewall CAPG
│       ├── iam/                  # Service Accounts + Workload Identity
│       ├── secret-manager/       # 8 secretos en GCP SM (valores placeholder)
│       └── cloud-dns/            # Zona navarro-bores.com (NS ya delegados a GCP)
│
├── bootstrap/                    # Setup inicial en Mac local
│   ├── 01-install-local-deps.sh  # Instala: kind, clusterctl, kubectl, helm, flux
│   ├── 02-init-capg.sh           # clusterctl init --infrastructure gcp
│   └── 03-build-gce-image.sh     # Imagen Ubuntu 22.04 + kubeadm + gVisor + Kata
│
├── cluster-api/                  # Manifiestos CAPI para el Workload Cluster
│   ├── cluster.yaml              # GCPCluster + Cluster (bc-workload)
│   ├── control-plane.yaml        # KubeadmControlPlane (1x e2-standard-4)
│   └── workers.yaml              # MachineDeployment (3x e2-standard-4 + disco 200GB Ceph)
│
├── flux/clusters/bc-workload/    # Árbol GitOps sincronizado por Flux
│   ├── flux-system/
│   │   └── kustomizations.yaml   # Orden de sync con dependsOn entre capas
│   ├── infrastructure/           # Cilium, cert-manager, External Secrets, CSI GCP
│   ├── security/                 # Keycloak, SPIRE, OPA, OpenZiti, Dex
│   ├── networking/               # Traefik + IngressRoutes + Middlewares
│   ├── messaging/                # NATS JetStream (3 réplicas, streams DORA/AUDIT)
│   ├── data/                     # Rook-Ceph, PostgreSQL, Qdrant, Trino
│   ├── applications/             # Deployments + ExternalSecrets + NetworkPolicies
│   │   ├── edge-security/        # Rust/Axum + Biscuit + NATS NKey
│   │   ├── ingestion-agent/      # Python CDC + DORA classifier
│   │   ├── frontend/             # React/Vite + Traefik IngressRoute
│   │   ├── runtimeclasses.yaml   # gVisor (runsc) + kata-containers
│   │   └── image-automation.yaml # Flux Image Automation (GHCR → auto-commit)
│   └── observability/            # kube-prometheus-stack + Loki + Hubble
│
├── dev-env/                      # Herramientas de puente dev↔prod (NO son K8s)
│   ├── docker-compose.prod.yml   # Override prod con ziti-tunnel sidecar
│   └── scripts/
│       └── setup-ziti-dev.sh     # Automatización NetFoundry: identidades + NKeys
│
├── setup_all.sh                  # Script maestro de bootstrap (13 pasos)
├── cleanup_demo.sh               # Destrucción total (garantía €0)
└── .gitignore
```

---

## Prerequisitos

### Local (Mac)
```bash
# Instalar automáticamente con:
./bootstrap/01-install-local-deps.sh

# O manualmente:
brew install kind kubectl helm flux clusterctl jq
brew install --cask google-cloud-sdk
```

### GCP
- Proyecto GCP con billing activo
- `gcloud auth application-default login`
- Permisos: `roles/owner` o equivalente personalizado

### Variables de entorno requeridas
```bash
export GCP_PROJECT_ID="tu-proyecto-gcp"
export FLUX_GITHUB_TOKEN="ghp_..."    # PAT con permisos repo + packages
export GCP_REGION="europe-west1"      # (default)
```

### Secrets en GCP Secret Manager
Creados automáticamente por Terraform con valores placeholder.
Rellenar antes del deploy:

| Secret | Descripción |
|---|---|
| `blueupalm/biscuit-root-key-pkcs8` | Clave privada Ed25519 para firma de tokens Biscuit |
| `blueupalm/nats-nkey-seed-edge` | Seed NKey para edge-security |
| `blueupalm/nats-nkey-seed-ingestor` | Seed NKey para ingestion-agent |
| `blueupalm/nats-nkey-seed-admin` | Seed NKey para administración NATS |
| `blueupalm/keycloak-admin-password` | Password admin Keycloak |
| `blueupalm/postgres-password` | Password PostgreSQL |
| `blueupalm/qdrant-api-key` | API Key Qdrant |
| `blueupalm/flux-github-token` | GitHub PAT para Flux Image Automation |

---

## Despliegue Completo

```bash
# 1. Clonar y configurar
git clone git@github.com:arnavarr/blueupalm-gitops.git
cd blueupalm-gitops

# 2. Configurar variables
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Editar terraform.tfvars con tu GCP_PROJECT_ID

# 3. Bootstrap completo (13 pasos automáticos)
export GCP_PROJECT_ID="tu-proyecto"
export FLUX_GITHUB_TOKEN="ghp_..."
./setup_all.sh
```

El script ejecuta en orden:
1. `terraform apply` → VPC, IAM, Secret Manager, Cloud DNS
2. Bootstrap Management Cluster local (`kind` en Mac)
3. `clusterctl init --infrastructure gcp` (CAPG)
4. Imagen GCE custom (Ubuntu 22.04 + kubeadm + gVisor + Kata)
5. `kubectl apply` → Workload Cluster `bc-workload` via CAPI
6. Esperar cluster Ready (~15-30 min)
7. Obtener kubeconfig del Workload Cluster
8. `flux bootstrap github` → sincroniza desde `blueupalm-gitops`
9. Esperar `infrastructure/` Ready (Cilium, cert-manager, External Secrets)
10. Validar External Secrets sincronizados desde GCP SM
11. Esperar `security/` Ready (Keycloak, SPIRE, OPA, OpenZiti, Dex)
12. Validar NATS JetStream 3/3 réplicas + streams AUDIT_TRAIL/VERIFY_STREAM/DORA_ALERTS
13. Esperar `applications/` Ready (edge-security, ingestion-agent, frontend)

**Resultado:**
```
https://blueupalm.navarro-bores.com    → Frontend AML
https://auth.navarro-bores.com         → Keycloak SSO
https://grafana.navarro-bores.com      → Grafana
https://hubble.navarro-bores.com       → Hubble UI (Cilium)
Coste estimado: ~$0.85/hora
```

---

## Pipeline CI/CD (Flux Image Automation)

```
./bc push → GitHub Actions → GHCR → Flux Image Policy → auto-commit → Flux sync → K8s rollout
```

Las imágenes se construyen en `arnavarr/bc` y Flux detecta nuevas versiones cada 5 minutos:

| Imagen | Registry | Workflow |
|---|---|---|
| `bc-edge-security` | `ghcr.io/arnavarr/bc-edge-security` | `build-edge-security.yml` |
| `bc-ingestion-agent` | `ghcr.io/arnavarr/bc-ingestion-agent` | `build-ingestion-agent.yml` |
| `bc-frontend` | `ghcr.io/arnavarr/bc-frontend` | `build-frontend.yml` |

---

## Limpieza (€0 garantizado)

```bash
./cleanup_demo.sh --purge-secrets
```

Destruye en orden: Services LoadBalancer → PVCs → Workload Cluster (CAPG) → Management Cluster (kind) → `terraform destroy`.

---

## Cumplimiento Regulatorio

| Regulación | Mecanismo |
|---|---|
| **DORA** | NATS JetStream 3 réplicas HA, buffer spool DORA, stream AUDIT_TRAIL 7 años |
| **PBC/FT** | Cilium NetworkPolicies L7, gVisor sandbox, SPIRE SVIDs corta duración |
| **RGPD Art.35** | Datos en `europe-west1`, cifrado en tránsito (WireGuard+Cilium), en reposo (Ceph) |
| **AI Act UE** | OPA para políticas de acceso LLM, Langfuse para auditoría de reasoning |
