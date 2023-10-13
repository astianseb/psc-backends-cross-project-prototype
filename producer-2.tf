############ PROJECT ###############

resource "google_project" "producer_2" {
  name                = "${var.producer_2_project_name}-${random_id.id.hex}"
  project_id          = "${var.producer_2_project_name}-${random_id.id.hex}"
  folder_id           = try(var.folder_id, false)
  billing_account     = var.billing_account
  auto_create_network = false
}

resource "google_project_service" "producer_2_service" {
  for_each = toset([
    "compute.googleapis.com",
    "servicedirectory.googleapis.com",
    "dns.googleapis.com"
  ])

  service            = each.key
  project            = google_project.producer_2.project_id
  disable_on_destroy = false
}

# ####### VPC NETWORK

resource "google_compute_network" "producer_2_vpc_network" {
  name                    = "my-internal-app"
  auto_create_subnetworks = false
  mtu                     = 1460
  project                 = google_project.producer_2.project_id
}


# ####### VPC SUBNETS

resource "google_compute_subnetwork" "producer_2_sb_subnet_a" {
  name          = "subnet-a"
  project       = google_project.producer_2.project_id
  region        = local.region-c
  ip_cidr_range = "10.10.20.0/24"
  network       = google_compute_network.producer_2_vpc_network.id
}

resource "google_compute_subnetwork" "producer_2_sb_subnet_b" {
  name          = "subnet-b"
  project       = google_project.producer_2.project_id
  region        = local.region-c
  ip_cidr_range = "10.10.40.0/24"
  network       = google_compute_network.producer_2_vpc_network.id
}

resource "google_compute_subnetwork" "producer_2_proxy" {
  name          = "l7-ilb-proxy-subnet"
  project       = google_project.producer_2.project_id
  region        = local.region-c
  ip_cidr_range = "10.10.200.0/24"
  network       = google_compute_network.producer_2_vpc_network.id
  purpose       = "REGIONAL_MANAGED_PROXY"
  role          = "ACTIVE"


}

####### FIREWALL

resource "google_compute_firewall" "producer_2_fw-allow-internal" {
  name      = "sg-allow-internal"
  project   = google_project.producer_2.project_id
  network   = google_compute_network.producer_2_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }

  source_ranges = [
    google_compute_subnetwork.producer_2_sb_subnet_a.ip_cidr_range,
    google_compute_subnetwork.producer_2_sb_subnet_b.ip_cidr_range]
}

resource "google_compute_firewall" "producer_2_fw_allow_ssh" {
  name      = "sg-allow-ssh"
  project   = google_project.producer_2.project_id
  network   = google_compute_network.producer_2_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "producer_2_fw_app_allow_http" {
  name      = "sg-app-allow-http"
  project   = google_project.producer_2.project_id
  network   = google_compute_network.producer_2_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }
  target_tags   = ["lb-backend"]
  source_ranges = ["0.0.0.0/0"]
}

resource "google_compute_firewall" "producer_2_fw_app_allow_health_check" {
  name      = "sg-app-allow-health-check"
  project   = google_project.producer_2.project_id
  network   = google_compute_network.producer_2_vpc_network.name
  direction = "INGRESS"

  allow {
    protocol = "tcp"
  }
  target_tags   = ["lb-backend"]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
}

#### NAT

resource "google_compute_router" "producer_2_router" {
  name    = "nat-router"
  project = google_project.producer_2.project_id
  region  = local.region-c
  network = google_compute_network.producer_2_vpc_network.id

  bgp {
    asn = 64514
  }
}

resource "google_compute_router_nat" "producer_2_nat" {
  name                               = "my-router-nat"
  project                            = google_project.producer_2.project_id
  region                             = local.region-c
  router                             = google_compute_router.producer_2_router.name
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

###################### HTTPS Regional LB #####################

# Self-signed regional SSL certificate for testing
resource "tls_private_key" "producer_2" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "producer_2" {
  private_key_pem = tls_private_key.producer_2.private_key_pem

  # Certificate expires after 48 hours.
  validity_period_hours = 48

  # Generate a new certificate if Terraform is run within three
  # hours of the certificate's expiration time.
  early_renewal_hours = 3

  # Reasonable set of uses for a server SSL certificate.
  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = ["sg-test-producer.com"]

  subject {
    common_name  = "sg-test-producer.com"
    organization = "SG Test Producer"
  }
}

resource "google_compute_region_ssl_certificate" "producer_2" {
  project     = google_project.producer_2.project_id
  name_prefix = "my-certificate-"
  private_key = tls_private_key.producer_2.private_key_pem
  certificate = tls_self_signed_cert.producer_2.cert_pem
  region      = local.region-c
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_region_health_check" "p2_tcp_health_check" {
  name               = "tcp-health-check"
  project            = google_project.producer_2.project_id
  region             = local.region-c 
  timeout_sec        = 1
  check_interval_sec = 1


  tcp_health_check {
    port = "80"
  }
}


// ------------- Instance Group A
resource "google_compute_instance_template" "p2_tmpl_instance_group_1" {
  name                 = "instance-group-1"
  project              = google_project.producer_2.project_id
  region               = local.region-c
  description          = "SG instance group of preemptible hosts"
  instance_description = "description assigned to instances"
  machine_type         = "e2-medium"
  can_ip_forward       = false
  tags                 = ["lb-backend"]

  scheduling {
    preemptible       = true
    automatic_restart = false

  }
  
  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  // Create a new boot disk from an image
  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network            = google_compute_network.producer_2_vpc_network.name
    subnetwork         = google_compute_subnetwork.producer_2_sb_subnet_a.name
    subnetwork_project = google_project.producer_2.project_id
  }

  metadata = {
    startup-script-url = "gs://cloud-training/gcpnet/ilb/startup.sh"
  }
}

#MIG-a
resource "google_compute_instance_group_manager" "p2_grp_instance_group_1" {
  name               = "instance-group-1"
  project            = google_project.producer_2.project_id
  base_instance_name = "mig-a"
  zone               = local.p2-zone-a
  version {
    instance_template = google_compute_instance_template.p2_tmpl_instance_group_1.id
  }

  auto_healing_policies {
    health_check      = google_compute_region_health_check.p2_tcp_health_check.id
    initial_delay_sec = 300
  }
}

resource "google_compute_autoscaler" "p2_obj_my_autoscaler_a" {
  name    = "my-autoscaler-a"
  project = google_project.producer_2.project_id
  zone    = local.p2-zone-a
  target  = google_compute_instance_group_manager.p2_grp_instance_group_1.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 45

    cpu_utilization {
      target = 0.8
    }
  }
}


//----------------Instance Group B

resource "google_compute_instance_template" "p2_tmpl_instance_group_2" {
  name                 = "instance-group-2"
  project              = google_project.producer_2.project_id
  region               = local.region-c
  description          = "SG instance group of preemptible hosts"
  instance_description = "description assigned to instances"
  machine_type         = "e2-medium"
  can_ip_forward       = false
  tags                 = ["lb-backend"]

  scheduling {
    preemptible       = true
    automatic_restart = false

  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  disk {
    source_image = "debian-cloud/debian-10"
    auto_delete  = true
    boot         = true
  }

  network_interface {
    network            = google_compute_network.producer_2_vpc_network.name
    subnetwork         = google_compute_subnetwork.producer_2_sb_subnet_b.name
    subnetwork_project = google_project.producer_2.project_id
  }

  metadata = {
    startup-script-url = "gs://cloud-training/gcpnet/ilb/startup.sh"
  }
}

resource "google_compute_instance_group_manager" "p2_grp_instance_group_2" {
  name               = "instance-group-2"
  project            = google_project.producer_2.project_id
  base_instance_name = "mig-b"
  zone               = local.p2-zone-b
  version {
    instance_template = google_compute_instance_template.p2_tmpl_instance_group_2.id
  }

  auto_healing_policies {
    health_check      = google_compute_region_health_check.p2_tcp_health_check.id
    initial_delay_sec = 300
  }
}

resource "google_compute_autoscaler" "p2_obj_my_autoscaler_b" {
  name    = "my-autoscaler-b"
  project = google_project.producer_2.project_id
  zone    = local.p2-zone-b
  target  = google_compute_instance_group_manager.p2_grp_instance_group_2.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 45

    cpu_utilization {
      target = 0.8
    }
  }
}



# forwarding rule
resource "google_compute_forwarding_rule" "p2_app_forwarding_rule" {
  name                  = "l7-ilb-forwarding-rule"
  provider              = google-beta
  region                = local.region-c
  project               = google_project.producer_2.project_id
  ip_protocol           = "TCP"
  load_balancing_scheme = "INTERNAL_MANAGED"
  port_range            = "443"
  target                = google_compute_region_target_https_proxy.producer_2.id
 # ip_address            = google_compute_address.default.id
  network               = google_compute_network.producer_2_vpc_network.id
  subnetwork            = google_compute_subnetwork.producer_2_sb_subnet_a.id
  allow_global_access   = true

}

# http proxy
resource "google_compute_region_target_https_proxy" "producer_2" {
  name     = "l7-ilb-target-http-proxy"
  provider = google-beta
  region   = local.region-c
  project  = google_project.producer_2.project_id
  url_map  = google_compute_region_url_map.producer_2.id
  
  ssl_certificates = [google_compute_region_ssl_certificate.producer_2.self_link]

}

# url map
resource "google_compute_region_url_map" "producer_2" {
  name            = "l7-ilb-url-map"
  provider        = google-beta
  region          = local.region-c
  project         = google_project.producer_2.project_id
  default_service = google_compute_region_backend_service.p2_app_backend.id
}


# HTTP regional load balancer (envoy based)
resource "google_compute_region_backend_service" "p2_app_backend" {
  name                     = "l7-ilb-backend-service"
  provider                 = google-beta
  region                   = local.region-c
  project                  = google_project.producer_2.project_id
  protocol                 = "HTTP"
  port_name                = "my-port"
  load_balancing_scheme    = "INTERNAL_MANAGED"
  timeout_sec              = 10
  health_checks            = [google_compute_region_health_check.p2_tcp_health_check.id]
  backend {
    group           = google_compute_instance_group_manager.p2_grp_instance_group_2.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
  backend {
    group           = google_compute_instance_group_manager.p2_grp_instance_group_2.instance_group
    balancing_mode  = "UTILIZATION"
    capacity_scaler = 1.0
  }
}


############ PUBLISH ########

resource "google_compute_subnetwork" "p2_sb_subnet_psc" {
  name          = "subnet-psc"
  project       = google_project.producer_2.project_id
  region        = local.region-c
  ip_cidr_range = "10.10.100.0/24"
  network       = google_compute_network.producer_2_vpc_network.id
  purpose       =  "PRIVATE_SERVICE_CONNECT"

}

resource "google_compute_service_attachment" "p2_psc_service_attachment" {
  name        = "my-psc-ilb"
  region      = local.region-c
  project     = google_project.producer_2.project_id
  description = "A service attachment configured with Terraform"

 # domain_names             = ["gcp.tfacc.hashicorptest.com."]
  enable_proxy_protocol    = false
  connection_preference    = "ACCEPT_AUTOMATIC"
  nat_subnets              = [google_compute_subnetwork.p2_sb_subnet_psc.id]
  target_service           = google_compute_forwarding_rule.p2_app_forwarding_rule.id
}


############### SIEGE HOST #####################

# Instance to host siege (testing tool for LB)
# usage: siege -i --concurrent=50 http://<lb-ip>
#

resource "google_compute_instance" "p2_producer_siege_host" {
  name         = "producer-siege-host"
  machine_type = "e2-medium"
  zone         = local.p2-zone-a
  project      = google_project.producer_2.project_id

  tags = ["siege"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-10"
    }
  }

  network_interface {
    network    = google_compute_network.producer_2_vpc_network.name
    subnetwork = google_compute_subnetwork.producer_2_sb_subnet_a.self_link
  }

  scheduling {
    preemptible       = true
    automatic_restart = false
  }

  shielded_instance_config {
    enable_integrity_monitoring = true
    enable_secure_boot          = true
    enable_vtpm                 = true
  }

  metadata = {
    enable-oslogin = true
  }


  metadata_startup_script = <<-EOF1
      #! /bin/bash
      set -euo pipefail

      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y siege
     EOF1

}