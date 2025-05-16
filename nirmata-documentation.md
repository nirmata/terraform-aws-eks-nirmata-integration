# Nirmata Integration Guide

This guide explains how to integrate an EKS cluster with Nirmata using our cross-platform Terraform solution.

## What This Solution Does

With a single `terraform apply` command, this solution will:

1. Create an EKS cluster in AWS
2. Register the cluster with Nirmata
3. Automatically download and apply Nirmata controller manifests
4. Work on both Windows and Linux systems without modification
5. Handle kubeconfig validation and recovery automatically

## Quick Start

```bash
# 1. Configure your variables in terraform.tfvars
cp terraform.tfvars.example terraform.tfvars
# Edit the file to add your Nirmata token and other required values

# 2. Initialize and apply
terraform init
terraform apply
```

That's it! Everything else happens automatically.

## How It Works: Under the Hood

### The One-Step Approach

We've solved a common Terraform challenge:
- Controller manifests are only generated *after* the cluster is registered with Nirmata
- But we want to apply them automatically in the same Terraform operation

Our solution uses:
- `null_resource` with `local-exec` provisioners to run commands after registration
- Proper `depends_on` to ensure the correct sequence of operations
- Automatic OS detection to use the right commands for your platform
- Robust kubeconfig validation and repair to prevent common failures

### Cross-Platform Compatibility

Our implementation automatically works on both Windows and Linux by:

```hcl
locals {
  is_windows = substr(pathexpand("~"), 0, 1) == "/" ? false : true
}
```

This simple code detects your OS and activates the appropriate resource:

#### For Windows:
- Uses PowerShell commands
- Handles Windows path syntax with backslashes
- Uses `Get-ChildItem` and `foreach` loops for file operations
- Uses `Start-Sleep` for pauses

#### For Linux/Unix:
- Uses bash/shell commands
- Uses Unix path syntax with forward slashes
- Uses shell globbing with asterisks
- Uses `sleep` command for pauses

### Robust Kubeconfig Handling

A common source of failure is corrupted or invalid kubeconfig files. Our solution includes:

```hcl
# For Linux/Unix
provisioner "local-exec" {
  command = <<-EOT
    # Ensure kubeconfig directory exists
    mkdir -p ~/.kube
    
    # Validate existing kubeconfig or create a new one
    if [ -f ~/.kube/config ]; then
      # Check if file is valid YAML
      if ! grep -q "apiVersion:" ~/.kube/config; then
        echo "Kubeconfig appears invalid, creating backup and new config"
        mv ~/.kube/config ~/.kube/config.bak.$(date +%s)
        touch ~/.kube/config
      fi
    else
      # Create empty config if it doesn't exist
      touch ~/.kube/config
    fi
    
    # Update kubeconfig with cluster info
    aws eks update-kubeconfig --region ${var.aws_region} --name ${local.cluster_name} --profile ${var.aws_profile}
  EOT
}
```

Similar logic is implemented for Windows environments, ensuring your kubeconfig is always valid.

### Individual File Handling

Instead of using wildcards which can be unreliable, our solution uses explicit file loops:

```hcl
# For Linux/Unix
provisioner "local-exec" {
  command = <<-EOT
    export CONTROLLER_FOLDER="${nirmata_cluster_registered.eks-registered.controller_yamls_folder}"
    for file in $CONTROLLER_FOLDER/temp-01-*; do
      echo "Applying namespace file: $file"
      kubectl apply -f $file
    done
  EOT
}
```

This approach:
- Makes sure every file is individually applied
- Provides detailed feedback on each operation
- Handles any filename variations
- Ensures consistent behavior across platforms

### The Controller Application Sequence

Controllers are applied in the correct order:
1. Namespace manifests (temp-01-*)
2. Service account manifests (temp-02-*)
3. CRD manifests (temp-03-*)
4. Deployment manifests (temp-04-*)

With appropriate waits between steps to ensure resources are ready.

## Troubleshooting

### Kubeconfig Issues

If you encounter problems with your kubeconfig:

```bash
# Reset your kubeconfig
rm ~/.kube/config && touch ~/.kube/config

# Reconfigure with your cluster
aws eks update-kubeconfig --region ${AWS_REGION} --name ${CLUSTER_NAME} --profile ${AWS_PROFILE}
```

### Variable Configuration

All configuration parameters can be set in `terraform.tfvars`:

```hcl
# Required
nirmata_token = "your-token-here"
nirmata_url = "https://nirmata.io"  # Or your specific Nirmata instance URL

# Optional - customize as needed
nirmata_cluster_name = "eks-cluster"
nirmata_cluster_type = "default-addons-type"
cluster_name = "eks-cluster"
cluster_version = "1.32"
aws_region = "us-west-1"
aws_profile = "default"
```

### Backup Files

If you encounter platform-specific issues, you can use platform-specific implementations:

**Platform-specific files:**
- `nirmata-integrated-windows.tf.backup` - Windows-only version
- `nirmata-integrated-linux.tf.backup` - Linux-only version

**To use a backup file:**

```bash
# 1. Disable current file
mv nirmata-integrated.tf nirmata-integrated.tf.disabled

# 2. Use Windows or Linux specific version
# For Windows:
cp nirmata-integrated-windows.tf.backup nirmata-integrated.tf

# OR for Linux:
cp nirmata-integrated-linux.tf.backup nirmata-integrated.tf

# 3. Apply
terraform apply
```

### Manual Controller Application

If automatic controller deployment fails, you can manually apply each file:

```bash
# Get the controller files folder
FOLDER=$(terraform output -raw controller_yamls_folder)

# Apply namespace manifests
for file in $FOLDER/temp-01-*; do
  kubectl apply -f $file
done

# Apply service account manifests (after waiting 10s)
sleep 10
for file in $FOLDER/temp-02-*; do
  kubectl apply -f $file
done

# Apply CRD manifests (after waiting 10s) 
sleep 10
for file in $FOLDER/temp-03-*; do
  kubectl apply -f $file
done

# Apply deployment manifests (after waiting 20s)
sleep 20
for file in $FOLDER/temp-04-*; do
  kubectl apply -f $file
done
```

## Verification

Verify your installation with:

```bash
# Check EKS nodes
kubectl get nodes

# Check Nirmata controllers
kubectl get pods -n nirmata
```

Also check the Nirmata web console to confirm the cluster appears as registered. 