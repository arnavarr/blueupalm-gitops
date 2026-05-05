# Misión — Infra Repository

## Objetivo
Gestionar la infraestructura completa de BlueUPALM mediante GitOps, incluyendo:
- Provisioning de cluster Kubernetes (Talos Linux via CAPI/CAPG)
- Despliegue de servicios mediante FluxCD
- Control de costes GCP mediante scripts de hibernación
- Gestión de secretos y certificados

## Alcance
- Todo recurso GCP está definido en Terraform
- Todo despliegue en K8s está definido en manifiestos FluxCD
- La política de coste cero fuera de horario es innegociable

## Fuera de Alcance
- Lógica de negocio (→ repo `bc`)
- Cliente desktop (→ repo `ztaclient`)
- Documentación técnica (→ repo `docs`)
