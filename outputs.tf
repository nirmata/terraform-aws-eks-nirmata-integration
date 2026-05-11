output "cluster_id" {
  description = "EKS cluster ID"
  value       = module.eks.cluster_id
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = module.eks.cluster_security_group_id
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = module.eks.cluster_certificate_authority_data
}

output "node_group_id" {
  description = "EKS Node Group ID"
  value       = module.eks.node_group_id
}

output "kubeconfig_command" {
  description = "Command to configure kubectl (run on a host with access to the EKS endpoint)"
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${var.cluster_name} --profile ${var.aws_profile}"
}

# Pipeline-facing outputs — the downstream automation script consumes these
# to apply the Nirmata controller manifests against the cluster.
output "aws_region" {
  description = "AWS region of the EKS cluster (for the downstream pipeline)"
  value       = var.aws_region
}

output "cluster_name" {
  description = "EKS cluster name (for the downstream pipeline)"
  value       = var.cluster_name
}

output "nirmata_cluster_name" {
  description = "Cluster name as registered in Nirmata"
  value       = var.nirmata_cluster_name
} 