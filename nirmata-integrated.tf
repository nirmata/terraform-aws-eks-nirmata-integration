# Provider configuration for Nirmata
provider "nirmata" {
  # Nirmata API Key - set this in terraform.tfvars
  token = var.nirmata_token
  # Nirmata URL
  url   = var.nirmata_url
}

# Reference the EKS cluster created by module.eks
locals {
  cluster_name                = module.eks.cluster_id
  cluster_endpoint            = module.eks.cluster_endpoint
  cluster_ca_certificate_data = module.eks.cluster_certificate_authority_data
}

# Register the EKS cluster with Nirmata.
# The provider downloads controller manifests to a local folder on the
# Terraform runner (controller_yamls_folder). The actual `kubectl apply`
# of those manifests is intentionally NOT performed in this workspace —
# the TFE runner cannot reach the EKS private endpoint. A downstream
# pipeline executed from a network-reachable host is responsible for
# applying the controllers using the outputs exposed below.
resource "nirmata_cluster_registered" "eks-registered" {
  name         = var.nirmata_cluster_name
  cluster_type = var.nirmata_cluster_type
  endpoint     = local.cluster_endpoint

  depends_on = [module.eks.cluster_id]
}

# Outputs consumed by the downstream automation pipeline
output "controller_yamls_folder" {
  description = "Local folder on the Terraform runner containing Nirmata controller YAML files. The downstream pipeline must collect these (e.g. upload to artifact storage) before the runner is destroyed."
  value       = nirmata_cluster_registered.eks-registered.controller_yamls_folder
}

output "controller_ns_yamls_count" {
  description = "Number of namespace YAML files (temp-01-*)"
  value       = nirmata_cluster_registered.eks-registered.controller_ns_yamls_count
}

output "controller_sa_yamls_count" {
  description = "Number of service account YAML files (temp-02-*)"
  value       = nirmata_cluster_registered.eks-registered.controller_sa_yamls_count
}

output "controller_crd_yamls_count" {
  description = "Number of CRD YAML files (temp-03-*)"
  value       = nirmata_cluster_registered.eks-registered.controller_crd_yamls_count
}

output "controller_deploy_yamls_count" {
  description = "Number of deployment YAML files (temp-04-*)"
  value       = nirmata_cluster_registered.eks-registered.controller_deploy_yamls_count
}
