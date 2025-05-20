variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
  default     = "eks-cluster"
}

variable "cluster_version" {
  description = "Kubernetes version to use for the EKS cluster"
  type        = string
  default     = "1.32"
}

variable "aws_region" {
  description = "AWS region where the EKS cluster will be created"
  type        = string
  default     = "us-west-1"
}

variable "aws_profile" {
  description = "AWS profile to use for authentication"
  type        = string
  default     = "default"
}

variable "vpc_id" {
  description = "VPC ID where the EKS cluster will be created"
  type        = string
  default     = "vpc-01a1c8d10eb2bb2ac"
}

variable "subnet_ids" {
  description = "Subnet IDs where the EKS cluster nodes will be deployed"
  type        = list(string)
  default     = ["subnet-04309b222eb8fd488", "subnet-0dff3fad15acc9156"]
}

variable "vpn_sg_id" {
  description = "Security Group ID for VPN access"
  type        = string
  default     = "sg-034c6b8a750d806ce"
}

variable "use_existing_roles" {
  description = "Whether to use existing IAM roles instead of creating new ones"
  type        = bool
  default     = false
}

variable "existing_cluster_role_name" {
  description = "Name or ARN of existing IAM role for EKS cluster (if use_existing_roles is true)"
  type        = string
  default     = ""
}

variable "existing_node_role_name" {
  description = "Name or ARN of existing IAM role for EKS node group (if use_existing_roles is true)"
  type        = string
  default     = ""
} 