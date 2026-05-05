# Conductor — Infra Repository

## Documentos de Gobernanza

| Documento | Propósito |
|:----------|:----------|
| [mission.md](mission.md) | Misión y alcance del repo infra |
| [tech-stack.md](tech-stack.md) | Stack técnico: Terraform, FluxCD, CAPI, Talos |
| [workflow.md](workflow.md) | Flujos de trabajo operativos |
| [decision-log.md](decision-log.md) | Registro de decisiones arquitectónicas |

## Regla Crítica

> **Toda sesión de prueba debe terminar con `hibernate.sh` o `cleanup_demo.sh`.**
> Verificar con `gcloud compute instances list` que no quedan VMs activas.
