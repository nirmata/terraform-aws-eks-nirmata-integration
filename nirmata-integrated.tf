# Provider configuration for Nirmata
provider "nirmata" {
  # Nirmata API Key - set this in terraform.tfvars
  token = var.nirmata_token
  # Nirmata URL
  url   = "https://staging.nirmata.co"
}

# Reference to the already created EKS cluster from module.eks
# instead of using data source which requires the cluster to exist first
locals {
  cluster_name                = module.eks.cluster_id
  cluster_endpoint            = module.eks.cluster_endpoint
  cluster_ca_certificate_data = module.eks.cluster_certificate_authority_data
  is_windows                  = substr(pathexpand("~"), 0, 1) == "/" ? false : true
}

# Register the EKS cluster with Nirmata
resource "nirmata_cluster_registered" "eks-registered" {
  name         = var.nirmata_cluster_name
  cluster_type = var.nirmata_cluster_type
  endpoint     = local.cluster_endpoint
  
  # Make sure this depends on the EKS cluster being fully created
  depends_on = [module.eks.cluster_id]
}

# Use local-exec provisioner to apply the controller manifests - Windows version
resource "null_resource" "apply_controllers_windows" {
  count = local.is_windows ? 1 : 0
  
  # Only proceed if the cluster is registered
  depends_on = [nirmata_cluster_registered.eks-registered]
  
  # This forces it to run every time, even if the resource attributes haven't changed
  triggers = {
    always_run = "${timestamp()}"
  }

  # Configure kubectl
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region us-west-1 --name ${local.cluster_name} --profile devtest-sso"
  }
  
  # List controller files for debugging
  provisioner "local-exec" {
    command = <<EOT
      $folder = "${replace(nirmata_cluster_registered.eks-registered.controller_yamls_folder, "/", "\\")}"
      Get-ChildItem -Path $folder | Out-File -FilePath controller_files.txt
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  # Apply namespace manifests (temp-01-*)
  provisioner "local-exec" {
    command = <<EOT
      $folder = "${replace(nirmata_cluster_registered.eks-registered.controller_yamls_folder, "/", "\\")}"
      $files = Get-ChildItem -Path $folder -Filter "temp-01-*"
      foreach ($file in $files) {
        Write-Host "Applying namespace file: $($file.FullName)"
        kubectl apply -f $file.FullName
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  # Wait for namespace to be ready
  provisioner "local-exec" {
    command = "Start-Sleep -Seconds 10"
    interpreter = ["PowerShell", "-Command"]
  }

  # Apply service account manifests (temp-02-*)
  provisioner "local-exec" {
    command = <<EOT
      $folder = "${replace(nirmata_cluster_registered.eks-registered.controller_yamls_folder, "/", "\\")}"
      $files = Get-ChildItem -Path $folder -Filter "temp-02-*"
      foreach ($file in $files) {
        Write-Host "Applying service account file: $($file.FullName)"
        kubectl apply -f $file.FullName
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  # Wait for service accounts to be ready
  provisioner "local-exec" {
    command = "Start-Sleep -Seconds 10"
    interpreter = ["PowerShell", "-Command"]
  }

  # Apply CRD manifests (temp-03-*)
  provisioner "local-exec" {
    command = <<EOT
      $folder = "${replace(nirmata_cluster_registered.eks-registered.controller_yamls_folder, "/", "\\")}"
      $files = Get-ChildItem -Path $folder -Filter "temp-03-*"
      foreach ($file in $files) {
        Write-Host "Applying CRD file: $($file.FullName)"
        kubectl apply -f $file.FullName
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }

  # Wait for CRDs to be ready
  provisioner "local-exec" {
    command = "Start-Sleep -Seconds 20"
    interpreter = ["PowerShell", "-Command"]
  }

  # Apply deployment manifests (temp-04-*)
  provisioner "local-exec" {
    command = <<EOT
      $folder = "${replace(nirmata_cluster_registered.eks-registered.controller_yamls_folder, "/", "\\")}"
      $files = Get-ChildItem -Path $folder -Filter "temp-04-*"
      foreach ($file in $files) {
        Write-Host "Applying deployment file: $($file.FullName)"
        kubectl apply -f $file.FullName
      }
    EOT
    interpreter = ["PowerShell", "-Command"]
  }
}

# Use local-exec provisioner to apply the controller manifests - Linux/Unix version
resource "null_resource" "apply_controllers_linux" {
  count = local.is_windows ? 0 : 1
  
  # Only proceed if the cluster is registered
  depends_on = [nirmata_cluster_registered.eks-registered]
  
  # This forces it to run every time, even if the resource attributes haven't changed
  triggers = {
    always_run = "${timestamp()}"
  }

  # Configure kubectl
  provisioner "local-exec" {
    command = "aws eks update-kubeconfig --region us-west-1 --name ${local.cluster_name} --profile devtest-sso"
  }
  
  # List controller files for debugging
  provisioner "local-exec" {
    command = "ls -la ${nirmata_cluster_registered.eks-registered.controller_yamls_folder} > controller_files.txt"
  }

  # Apply namespace manifests
  provisioner "local-exec" {
    command = "kubectl apply -f ${nirmata_cluster_registered.eks-registered.controller_yamls_folder}/temp-01-*"
  }

  # Wait for namespace to be ready
  provisioner "local-exec" {
    command = "sleep 10"
  }

  # Apply service account manifests
  provisioner "local-exec" {
    command = "kubectl apply -f ${nirmata_cluster_registered.eks-registered.controller_yamls_folder}/temp-02-*"
  }

  # Wait for service accounts to be ready
  provisioner "local-exec" {
    command = "sleep 10"
  }

  # Apply CRD manifests
  provisioner "local-exec" {
    command = "kubectl apply -f ${nirmata_cluster_registered.eks-registered.controller_yamls_folder}/temp-03-*"
  }

  # Wait for CRDs to be ready
  provisioner "local-exec" {
    command = "sleep 20"
  }

  # Apply deployment manifests
  provisioner "local-exec" {
    command = "kubectl apply -f ${nirmata_cluster_registered.eks-registered.controller_yamls_folder}/temp-04-*"
  }
}

# Output the controller YAML folder path for reference
output "controller_yamls_folder" {
  description = "Folder containing Nirmata controller YAML files"
  value       = nirmata_cluster_registered.eks-registered.controller_yamls_folder
}

output "controller_ns_yamls_count" {
  description = "Number of namespace YAML files"
  value       = nirmata_cluster_registered.eks-registered.controller_ns_yamls_count
}

output "controller_sa_yamls_count" {
  description = "Number of service account YAML files"
  value       = nirmata_cluster_registered.eks-registered.controller_sa_yamls_count
}

output "controller_crd_yamls_count" {
  description = "Number of CRD YAML files"
  value       = nirmata_cluster_registered.eks-registered.controller_crd_yamls_count
}

output "controller_deploy_yamls_count" {
  description = "Number of deployment YAML files"
  value       = nirmata_cluster_registered.eks-registered.controller_deploy_yamls_count
} 