# Workflow — Infra Repository

## Flujo de Despliegue

1. **Provisioning** → `terraform apply` (VMs, redes, IPs)
2. **Bootstrap** → `bootstrap.sh` (CAPI pivot, Talos config)
3. **GitOps** → FluxCD reconcilia manifiestos automáticamente
4. **Verificación** → `kubectl get nodes`, `flux get all`
5. **Hibernación** → `hibernate.sh` al terminar

## Convenciones de Commits
- `infra:` — Cambios en Terraform
- `flux:` — Cambios en manifiestos FluxCD
- `capi:` — Cambios en definición del cluster
- `ops:` — Scripts operativos

## Reglas
- NO aplicar Terraform sin revisar el plan
- NO dejar VMs activas fuera de sesiones de trabajo
- Toda IP estática debe eliminarse con `hibernate.sh`
- Los secretos van en Kubernetes Secrets, NUNCA en Git
