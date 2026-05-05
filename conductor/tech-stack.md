# Tech Stack — Infra Repository

## IaC
- **Terraform** — Provisioning GCP (VMs, redes, IPs, firewalls, IAM)
- **CAPI/CAPG** — Cluster API con provider GCP para gestión del cluster
- **CABPT** — Talos Bootstrap Provider para Talos Linux

## Cluster
- **Talos Linux v1.7.6** — OS inmutable para nodos K8s
- **Kubernetes v1.29.6** — Orquestación de contenedores
- **Cilium** — CNI con eBPF
- **gVisor** — Runtime sandboxing (pendiente activación)

## GitOps
- **FluxCD** — Reconciliación continua (8 capas, 29 manifiestos)
- **GHCR** — Container registry (imágenes desde repo `bc`)
- **ImagePolicy/ImageRepository** — Detección automática de nuevas versiones

## Seguridad
- **SPIRE** — Identidad SPIFFE para mTLS
- **OpenZiti/NetFoundry** — Overlay Zero Trust
- **KMS** — Encriptación de secretos en Talos

## Operaciones
- **hibernate.sh** — Destruye VMs y LBs para coste cero
- **cleanup_demo.sh** — Limpieza post-demo
- **bootstrap.sh** — Provisioning desde cero
