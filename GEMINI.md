# BlueUPALM — Infraestructura y Operaciones (Runbook)

Este archivo contiene mandatos técnicos y procedimientos de resolución de problemas para el mantenimiento de la plataforma BlueUPALM.

## 🚀 Despliegue y Recuperación

### 1. Sincronización de Credenciales CAPG
Si Terraform regenera el archivo `bootstrap/capg-credentials.json` (por rotación de claves o recreación de la SA), el Management Cluster (kind) debe ser actualizado manualmente:

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
Si un cluster o máquina de CAPI se queda atascado en estado de eliminación (normalmente por falta de conectividad con el proveedor o recursos huérfanos en GCP), se debe forzar la limpieza de *finalizers*:

```bash
# Para el cluster principal
kubectl patch cluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge
kubectl patch gcpcluster bc-workload -p '{"metadata":{"finalizers":null}}' --type=merge

# Para máquinas individuales (si es necesario)
kubectl patch gcpmachine <nombre-maquina> -p '{"metadata":{"finalizers":null}}' --type=merge
```

### 3. Dependencia de Imagen GCE
El Workload Cluster depende de una imagen GCE personalizada en la familia `blueupalm-k8s-node`. 
- **Si el despliegue falla con Error 404 (Image not found):** Ejecutar `bash bootstrap/03-build-gce-image.sh`.
- El controlador CAPG reintentará automáticamente una vez que la imagen esté disponible.

## 🛡️ Estándares de Hardening (DORA/PBC-FT)
- **Networking:** Los Load Balancers del API Server deben ser siempre de tipo `Internal` (especificado en `cluster-api/cluster.yaml`).
- **Auditoría:** El `KubeadmControlPlane` tiene activada la política de auditoría en `/etc/kubernetes/audit-policy.yaml` para registrar accesos a secretos.
- **DNS:** La zona de Cloud DNS tiene activado `prevent_destroy = true` en Terraform para proteger el dominio `navarro-bores.com`.
