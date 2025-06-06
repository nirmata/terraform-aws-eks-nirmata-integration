provider "aws" {
  region = var.aws_region
  profile = var.aws_profile
}

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    nirmata = {
      source  = "nirmata/nirmata"
      version = "~> 1.1"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
  required_version = ">= 1.2.0"
}

module "eks" {
  source = "./modules/eks"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = var.vpc_id
  subnet_ids      = var.subnet_ids
  vpn_sg_id       = var.vpn_sg_id
  
  # IAM role configuration
  use_existing_roles      = var.use_existing_roles
  existing_cluster_role_name = var.existing_cluster_role_name
  existing_node_role_name   = var.existing_node_role_name
} 