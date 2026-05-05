# Decision Log — Infra Repository

## Formato
Cada decisión sigue el formato ADR (Architecture Decision Record).

---

### ADR-001: Talos Linux sobre Ubuntu/Debian
- **Fecha:** 2026-05-03
- **Estado:** Aceptada
- **Contexto:** Se necesita un OS inmutable y auditable para cumplimiento DORA
- **Decisión:** Migrar de kubeadm sobre Ubuntu a Talos Linux via CAPI
- **Consecuencias:** FS inmutable (no se puede escribir audit-log en /var/log), bootstrap más complejo pero más seguro

### ADR-002: NetFoundry SaaS sobre OpenZiti self-hosted
- **Fecha:** 2026-04-20
- **Estado:** Aceptada
- **Contexto:** El overlay Zero Trust necesita un Controller. Self-hosted añade complejidad operativa
- **Decisión:** Usar NetFoundry como SaaS para el Controller, mantener solo los Edge Routers
- **Consecuencias:** Dependencia de NetFoundry SaaS, pero elimina operación del Controller

### ADR-003: Hibernación automática para coste cero
- **Fecha:** 2026-04-25
- **Estado:** Aceptada
- **Contexto:** El cluster GCP genera costes incluso inactivo (VMs, LBs, IPs)
- **Decisión:** Implementar `hibernate.sh` que destruye TODO excepto la definición Terraform
- **Consecuencias:** Cada sesión requiere ~15min de bootstrap, pero coste nocturno = 0€
