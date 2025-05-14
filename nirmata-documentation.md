# Nirmata Integration Guide

This guide explains how to integrate an EKS cluster with Nirmata using our cross-platform Terraform solution.

## What This Solution Does

With a single `terraform apply` command, this solution will:

1. Create an EKS cluster in AWS
2. Register the cluster with Nirmata
3. Automatically download and apply Nirmata controller manifests
4. Work on both Windows and Linux systems without modification

## Quick Start

```bash
# 1. Configure your Nirmata token in terraform.tfvars
echo 'nirmata_token = "your-token-here"' > terraform.tfvars

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

### The Controller Application Sequence

Controllers are applied in the correct order:
1. Namespace manifests (temp-01-*)
2. Service account manifests (temp-02-*)
3. CRD manifests (temp-03-*)
4. Deployment manifests (temp-04-*)

With appropriate waits between steps to ensure resources are ready.

## Troubleshooting

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

If automatic controller deployment fails, you can manually apply them:

```bash
# Apply namespace manifests
kubectl apply -f $(terraform output -raw controller_yamls_folder)/temp-01-*

# Apply service account manifests
kubectl apply -f $(terraform output -raw controller_yamls_folder)/temp-02-*

# Apply CRD manifests
kubectl apply -f $(terraform output -raw controller_yamls_folder)/temp-03-*

# Apply deployment manifests
kubectl apply -f $(terraform output -raw controller_yamls_folder)/temp-04-*
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