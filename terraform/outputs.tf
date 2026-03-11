# ─────────────────────────────────────────────────────────────
# Outputs — values needed for K8s manifests and kubectl setup
# ─────────────────────────────────────────────────────────────

output "cluster_id" {
  description = "OCID of the OKE cluster"
  value       = oci_containerengine_cluster.gpu_cluster.id
}

output "cluster_name" {
  description = "Name of the OKE cluster"
  value       = oci_containerengine_cluster.gpu_cluster.name
}

output "cluster_kubernetes_version" {
  description = "Kubernetes version running on the cluster"
  value       = oci_containerengine_cluster.gpu_cluster.kubernetes_version
}

output "cpu_node_pool_id" {
  description = "OCID of the CPU node pool (use in cluster-autoscaler --nodes flag)"
  value       = oci_containerengine_node_pool.cpu_pool.id
}

output "gpu_node_pool_id" {
  description = "OCID of the GPU node pool (use in cluster-autoscaler --nodes flag)"
  value       = oci_containerengine_node_pool.gpu_pool.id
}

output "kubeconfig_command" {
  description = "Command to generate kubeconfig for this cluster"
  value       = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.gpu_cluster.id} --file $HOME/.kube/config --region ${var.region} --token-version 2.0.0"
}
