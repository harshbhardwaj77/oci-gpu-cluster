# ─────────────────────────────────────────────────────────────
# OCI GPU Kubernetes Cluster (OKE)
# GPU nodes scale to zero when idle, auto-provision on demand
# ─────────────────────────────────────────────────────────────

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 5.0"
    }
  }
}

provider "oci" {
  region = var.region
}

# ── Data Sources ───────────────────────────────────────────

data "oci_identity_availability_domains" "ads" {
  compartment_id = var.compartment_id
}

data "oci_containerengine_node_pool_option" "opts" {
  node_pool_option_id = oci_containerengine_cluster.gpu_cluster.id
  compartment_id      = var.compartment_id
}

# Resolve image IDs — prefer user-provided, fall back to first available
locals {
  # Pick the first Oracle-provided image if not explicitly set
  default_image_id = data.oci_containerengine_node_pool_option.opts.sources[0].image_id
  cpu_image_id     = var.cpu_node_image_id != "" ? var.cpu_node_image_id : local.default_image_id
  gpu_image_id     = var.gpu_node_image_id != "" ? var.gpu_node_image_id : local.default_image_id

  first_ad = data.oci_identity_availability_domains.ads.availability_domains[0].name
}

# ── OKE Cluster ────────────────────────────────────────────

resource "oci_containerengine_cluster" "gpu_cluster" {
  compartment_id     = var.compartment_id
  kubernetes_version = var.k8s_version
  name               = "llama-gpu-cluster"
  vcn_id             = var.vcn_id

  endpoint_config {
    is_public_ip_enabled = true
    subnet_id            = var.k8s_endpoint_subnet_id
  }

  options {
    service_lb_subnet_ids = [var.service_lb_subnet_id]

    kubernetes_network_config {
      pods_cidr     = "10.244.0.0/16"
      services_cidr = "10.96.0.0/16"
    }
  }
}

# ── CPU Node Pool (system workloads — always on) ───────────

resource "oci_containerengine_node_pool" "cpu_pool" {
  cluster_id         = oci_containerengine_cluster.gpu_cluster.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.k8s_version
  name               = "cpu-system-pool"
  node_shape         = var.cpu_node_shape

  node_shape_config {
    ocpus         = var.cpu_node_ocpus
    memory_in_gbs = var.cpu_node_memory_gbs
  }

  node_config_details {
    size = var.cpu_pool_size

    placement_configs {
      availability_domain = local.first_ad
      subnet_id           = var.node_subnet_id
    }
  }

  node_source_details {
    image_id    = local.cpu_image_id
    source_type = "IMAGE"
  }

  initial_node_labels {
    key   = "workload-type"
    value = "system"
  }

  ssh_public_key = var.ssh_public_key
}

# ── GPU Node Pool (scale-to-zero) ─────────────────────────

resource "oci_containerengine_node_pool" "gpu_pool" {
  cluster_id         = oci_containerengine_cluster.gpu_cluster.id
  compartment_id     = var.compartment_id
  kubernetes_version = var.k8s_version
  name               = "gpu-inference-pool"
  node_shape         = var.gpu_node_shape

  node_config_details {
    # Start with ZERO GPU nodes — autoscaler provisions on demand
    size = var.gpu_pool_min_size

    placement_configs {
      availability_domain = local.first_ad
      subnet_id           = var.node_subnet_id
    }
  }

  node_source_details {
    # Must use the Oracle Linux GPU image (includes CUDA libs)
    image_id    = local.gpu_image_id
    source_type = "IMAGE"
  }

  initial_node_labels {
    key   = "nvidia.com/gpu.present"
    value = "true"
  }

  initial_node_labels {
    key   = "workload-type"
    value = "gpu-inference"
  }

  ssh_public_key = var.ssh_public_key
}
