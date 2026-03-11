# ─────────────────────────────────────────────────────────────
# OCI GPU Cluster — Variables
# ─────────────────────────────────────────────────────────────

variable "region" {
  description = "OCI region to deploy into"
  type        = string
  default     = "us-ashburn-1"
}

variable "compartment_id" {
  description = "OCID of the compartment for all resources"
  type        = string
}

variable "vcn_id" {
  description = "OCID of the existing VCN"
  type        = string
}

variable "k8s_endpoint_subnet_id" {
  description = "OCID of the subnet for the K8s API endpoint (public)"
  type        = string
}

variable "node_subnet_id" {
  description = "OCID of the subnet for worker nodes (private recommended)"
  type        = string
}

variable "service_lb_subnet_id" {
  description = "OCID of the subnet for OCI load balancers"
  type        = string
}

variable "ssh_public_key" {
  description = "SSH public key for node access"
  type        = string
}

variable "k8s_version" {
  description = "Kubernetes version for the OKE cluster"
  type        = string
  default     = "v1.30.1"
}

# ── CPU Node Pool ──────────────────────────────────────────

variable "cpu_node_shape" {
  description = "Shape for CPU worker nodes"
  type        = string
  default     = "VM.Standard.E4.Flex"
}

variable "cpu_node_ocpus" {
  description = "OCPUs per CPU node (flex shapes). 1 OCPU is enough for autoscaler + GPU operator."
  type        = number
  default     = 1
}

variable "cpu_node_memory_gbs" {
  description = "Memory in GB per CPU node (flex shapes). 8 GB is sufficient for system workloads."
  type        = number
  default     = 8
}

variable "cpu_pool_size" {
  description = "Number of CPU nodes (always-on). 1 is enough — just runs autoscaler + GPU operator."
  type        = number
  default     = 1
}

# ── GPU Node Pool ──────────────────────────────────────────

variable "gpu_node_shape" {
  description = "Shape for GPU worker nodes (VM.GPU.A10.1 = 1× NVIDIA A10 24GB)"
  type        = string
  default     = "VM.GPU.A10.1"
}

variable "gpu_pool_min_size" {
  description = "Minimum GPU nodes (set to 0 for scale-to-zero)"
  type        = number
  default     = 0
}

variable "gpu_pool_max_size" {
  description = "Maximum GPU nodes the autoscaler can provision"
  type        = number
  default     = 3
}

# ── Image ──────────────────────────────────────────────────

variable "gpu_node_image_id" {
  description = "OCID of the Oracle Linux GPU image (with CUDA). Leave empty to auto-select."
  type        = string
  default     = ""
}

variable "cpu_node_image_id" {
  description = "OCID of the Oracle Linux image for CPU nodes. Leave empty to auto-select."
  type        = string
  default     = ""
}
