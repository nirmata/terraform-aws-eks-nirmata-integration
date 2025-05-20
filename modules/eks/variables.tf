variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be created"
  type        = string
}

variable "subnet_ids" {
  description = "Subnet IDs where the EKS cluster nodes will be deployed"
  type        = list(string)
}

variable "vpn_sg_id" {
  description = "Security Group ID for VPN access"
  type        = string
}

variable "use_existing_roles" {
  description = "Whether to use existing IAM roles instead of creating new ones"
  type        = bool
  default     = false
}

variable "existing_cluster_role_name" {
  description = "Name of existing IAM role for EKS cluster (if use_existing_roles is true)"
  type        = string
  default     = ""
}

variable "existing_node_role_name" {
  description = "Name of existing IAM role for EKS node group (if use_existing_roles is true)"
  type        = string
  default     = ""
} 