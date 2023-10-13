# Topology comprises 3 projects:
# - project for consumer
# - projects for producer-1 and producer-2
# Every producer and consumer are in different regions
# region_a - consumer
# region_b - producer-1
# region_c - producer-2
#
#
# DOES NOT WORK AT THE MOMENT - 13.10.2023
# │ Error: Error creating RegionBackendService: googleapi: Error 400: Invalid value for field 'resource.backends[0]': '{  "group": "projects/consumer-sgb08c31f5/regions/europe-west2/networkEndpointGroups/p1-psc-neg",  "...'. Regional Backend services using Private Service Connect Network Endpoint Group as backends may only have 1 backend. Request contains multiple backends., invalid
# │ 
# │   with google_compute_region_backend_service.sg_psc_backend,
# │   on consumer.tf line 188, in resource "google_compute_region_backend_service" "sg_psc_backend":
# │  188: resource "google_compute_region_backend_service" "sg_psc_backend" {




locals {
  c-zone-a = "${var.region_a}-b"
  c-zone-b = "${var.region_a}-c"
  
  p1-zone-a = "${var.region_b}-b"
  p1-zone-b = "${var.region_b}-c"

  p2-zone-a = "${var.region_c}-b"
  p2-zone-b = "${var.region_c}-c"

  region-a = var.region_a
  region-b = var.region_b
  region-c = var.region_c
}

provider "google" {
#  region = var.region
}

resource "random_id" "id" {
  byte_length = 4
  prefix      = "sg"
}
