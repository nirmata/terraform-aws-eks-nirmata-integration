# Novartis EKS-Nirmata Integration

This Terraform configuration creates an EKS 1.32 cluster, registers it with Nirmata, and automatically deploys Nirmata controllers in a single operation. The implementation is cross-platform compatible, working on both Windows and Linux/Unix environments.

## Requirements

- Terraform >= 1.2.0
- AWS CLI configured with DevTest SSO profile (`devtest-sso`)
- kubectl installed
- AWS region set to `us-west-1`
- Nirmata account with API token

## Resources Created

- EKS Cluster version 1.32
- Node Group with 1 t3a.medium instance
- Security Group with appropriate access rules
- Nirmata cluster registration
- Nirmata controllers deployment

## Infrastructure Details

- VPC: vpc-01a1c8d10eb2bb2ac (DevTest VPC in us-west-1)
- Subnets: subnet-04309b222eb8fd488, subnet-0dff3fad15acc9156
- EKS Version: 1.32
- Node Group: 1x t3a.medium instance
- Networking: Public endpoint only (private endpoint disabled)
- IAM: Using devtest-sso profile for authentication and authorization

## Files Structure

- `main.tf` - Main EKS cluster configuration
- `nirmata-integrated.tf` - Cross-platform Nirmata integration
- `nirmata-variables.tf` - Nirmata-specific variables
- `nirmata-documentation.md` - Detailed documentation on the integration process
- `variables.tf` - Core terraform variables
- `modules/eks/` - EKS module files

## Quick Start

1. Configure your Nirmata token in `terraform.tfvars`:
   ```hcl
   nirmata_token = "your-nirmata-api-token"
   ```

2. Initialize and apply:
   ```bash
   terraform init
   terraform apply
   ```

   That's it! The single command will:
   - Create the complete EKS cluster
   - Register the cluster with Nirmata
   - Download controller YAML files from Nirmata
   - Apply the controller manifests to the cluster

## How It Works

### Cross-Platform Compatibility

This implementation automatically detects your operating system and uses appropriate commands:

```hcl
locals {
  is_windows = substr(pathexpand("~"), 0, 1) == "/" ? false : true
}
```

- **Windows Systems**: Uses PowerShell commands with proper Windows path handling
- **Linux/Unix Systems**: Uses standard shell commands with Unix paths

### Application Process

Controllers are applied in the correct sequence with appropriate waits between steps:
1. Namespace manifests (temp-01-*)
2. Service account manifests (temp-02-*)
3. CRD manifests (temp-03-*)
4. Deployment manifests (temp-04-*)

## Troubleshooting

### Common Issues

1. **AWS Authentication**: Ensure your AWS CLI is configured with the DevTest SSO profile
   ```bash
   aws configure --profile devtest-sso
   ```

2. **Nirmata Registration Errors**: Verify your Nirmata token is correct and has proper permissions

3. **Controller Application Failures**: Check controller_files.txt for logs of what was attempted

### Platform-Specific Considerations

If you encounter platform-specific issues, you can use the backup files:

- `nirmata-integrated-windows.tf.backup` - Windows-specific implementation
- `nirmata-integrated-linux.tf.backup` - Linux-specific implementation

See `nirmata-documentation.md` for detailed instructions on using these backup files.

## Manual Controller Application

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

## Cleanup

To destroy all resources:

```bash
terraform destroy
```

## Verification

To verify the installation:

1. Check the EKS cluster is running:
   ```bash
   kubectl get nodes
   ```

2. Verify Nirmata controllers are running:
   ```bash
   kubectl get pods -n nirmata
   ```

3. Check in Nirmata web console that the cluster appears as registered

## Detailed Documentation

For more detailed information about the integration process and troubleshooting, please refer to the [Nirmata Integration Guide](./nirmata-documentation.md).