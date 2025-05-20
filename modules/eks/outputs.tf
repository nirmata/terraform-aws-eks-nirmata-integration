output "cluster_id" {
  description = "EKS cluster ID"
  value       = local.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = local.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ID attached to the EKS cluster"
  value       = aws_security_group.eks_sg.id
}

output "cluster_arn" {
  description = "ARN of the EKS cluster"
  value       = var.use_existing_roles ? aws_eks_cluster.eks_cluster_with_existing_role[0].arn : aws_eks_cluster.eks_cluster_with_new_role[0].arn
}

output "cluster_certificate_authority_data" {
  description = "Base64 encoded certificate data required to communicate with the cluster"
  value       = local.cluster_certificate_authority_data
}

output "node_group_id" {
  description = "EKS Node Group ID"
  value       = var.use_existing_roles ? aws_eks_node_group.eks_node_group_existing_role[0].id : aws_eks_node_group.eks_node_group_new_role[0].id
}

output "node_group_arn" {
  description = "ARN of the EKS Node Group"
  value       = var.use_existing_roles ? aws_eks_node_group.eks_node_group_existing_role[0].arn : aws_eks_node_group.eks_node_group_new_role[0].arn
}

output "node_group_status" {
  description = "Status of the EKS Node Group"
  value       = var.use_existing_roles ? aws_eks_node_group.eks_node_group_existing_role[0].status : aws_eks_node_group.eks_node_group_new_role[0].status
} 