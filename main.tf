# Topology comprises 3 projects:
# - project for consumer
# - projects for producer-1 and producer-2
# Every producer and consumer can be in in different regions
# region_a - consumer
# region_b - producer-1
# region_c - producer-2
#
#CAVEAT: CROSS project is working only in a single region (Service Attachment region must equal PSC NEG region)


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
}


provider "google-beta" {
}

resource "random_id" "id" {
  byte_length = 4
  prefix      = "sg"
}
