# terraform/modules/vpc/main.tf
# BlueUPALM — Módulo VPC
# Red privada dedicada para el cluster Kubernetes sobre GCE (no-GKE)
# Las reglas de firewall siguen los requisitos de Cluster API Provider GCP (CAPG)

variable "project_id" { type = string }
variable "region"     { type = string }
variable "cluster_name" { type = string }

# ── VPC Principal ──────────────────────────────────────────────────────────────
resource "google_compute_network" "blueupalm_vpc" {
  name                    = "blueupalm-vpc"
  auto_create_subnetworks = false
  project                 = var.project_id
  description             = "VPC dedicada para BlueUPALM — Kubernetes no-GKE sobre GCE"
}

# ── Subnet Principal (europe-west1) ───────────────────────────────────────────
resource "google_compute_subnetwork" "blueupalm_subnet" {
  name          = "blueupalm-subnet-${var.region}"
  ip_cidr_range = "10.0.0.0/20"       # 4094 IPs para pods + nodos
  region        = var.region
  network       = google_compute_network.blueupalm_vpc.id
  project       = var.project_id

  # Rangos secundarios para pods y services (requerido por Cilium)
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.1.0.0/16"     # 65534 IPs para pods
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.2.0.0/20"     # 4094 IPs para services K8s
  }
}

# ── Firewall: Comunicación interna del cluster ─────────────────────────────────
resource "google_compute_firewall" "internal" {
  name    = "${var.cluster_name}-internal"
  network = google_compute_network.blueupalm_vpc.name
  project = var.project_id

  description = "Permite tráfico interno entre nodos del cluster (pods, services, NATS cluster routes)"

  allow {
    protocol = "tcp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "udp"
    ports    = ["0-65535"]
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = ["10.0.0.0/20", "10.1.0.0/16", "10.2.0.0/20"]
  target_tags   = ["${var.cluster_name}-node"]
}

# ── Firewall: API Server (acceso externo para kubectl) ────────────────────────
resource "google_compute_firewall" "api_server" {
  name    = "${var.cluster_name}-api-server"
  network = google_compute_network.blueupalm_vpc.name
  project = var.project_id

  description = "Permite acceso al kube-apiserver desde IPs autorizadas (setup_all.sh)"

  allow {
    protocol = "tcp"
    ports    = ["6443"]
  }

  # En producción, restringir a IPs corporativas específicas
  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-control-plane"]
}

# ── Firewall: Health checks de GCP (requerido por LoadBalancer) ───────────────
resource "google_compute_firewall" "health_checks" {
  name    = "${var.cluster_name}-health-checks"
  network = google_compute_network.blueupalm_vpc.name
  project = var.project_id

  description = "Permite health checks de GCP para LoadBalancers (Traefik Ingress)"

  allow {
    protocol = "tcp"
    ports    = ["80", "443", "8080", "10256"]
  }

  # Rangos oficiales de health checkers de GCP
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  target_tags   = ["${var.cluster_name}-node"]
}

# ── Firewall: SSH (solo para bootstrap/debugging) ─────────────────────────────
resource "google_compute_firewall" "ssh" {
  name    = "${var.cluster_name}-ssh"
  network = google_compute_network.blueupalm_vpc.name
  project = var.project_id

  description = "SSH para gestión de nodos — restringir a IPs corporativas en producción"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["${var.cluster_name}-node"]
}

# ── Cloud NAT (salida a internet para pulls de imágenes) ──────────────────────
resource "google_compute_router" "router" {
  name    = "${var.cluster_name}-router"
  region  = var.region
  network = google_compute_network.blueupalm_vpc.id
  project = var.project_id
}

resource "google_compute_router_nat" "nat" {
  name                               = "${var.cluster_name}-nat"
  router                             = google_compute_router.router.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

output "network_name" { value = google_compute_network.blueupalm_vpc.name }
output "network_id"   { value = google_compute_network.blueupalm_vpc.id }
output "subnet_name"  { value = google_compute_subnetwork.blueupalm_subnet.name }
output "subnet_id"    { value = google_compute_subnetwork.blueupalm_subnet.id }
