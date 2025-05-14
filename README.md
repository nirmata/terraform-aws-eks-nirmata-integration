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
- `nirmata-platform-readme.md` - Detailed documentation on platform-specific implementations
- `variables.tf` - Core terraform variables
- `modules/eks/` - EKS module files

## Complete Process

### Step 1: Create the EKS Cluster and Register with Nirmata

1. Configure your Nirmata token in `terraform.tfvars`:
   ```hcl
   nirmata_token = "your-nirmata-api-token"
   ```

2. Initialize Terraform:
   ```bash
   terraform init
   ```

3. Review the execution plan:
   ```bash
   terraform plan
   ```

4. Apply the configuration:
   ```bash
   terraform apply
   ```

   This single command will:
   - Create the complete EKS cluster
   - Register the cluster with Nirmata
   - Download controller YAML files from Nirmata
   - Apply the controller manifests to the cluster

5. The output will include:
   - EKS cluster details (name, endpoint)
   - Controller YAML files location
   - Number of manifests applied by type (namespace, service account, CRDs, deployments)

### How It Works

The implementation follows a modular approach:

1. **EKS Cluster Creation** - Creates the AWS EKS cluster using Terraform's AWS provider

2. **Nirmata Registration** - Uses the Nirmata provider to register the cluster:
   ```hcl
   resource "nirmata_cluster_registered" "eks-registered" {
     name         = var.nirmata_cluster_name
     cluster_type = var.nirmata_cluster_type
     endpoint     = local.cluster_endpoint
     depends_on   = [module.eks.cluster_id]
   }
   ```

3. **Controller Deployment** - Uses platform-detection for cross-platform compatibility:
   ```hcl
   locals {
     is_windows = substr(pathexpand("~"), 0, 1) == "/" ? false : true
   }
   ```

4. **Application Order** - Controllers are applied in the correct sequence:
   - Namespace manifests (temp-01-*)
   - Service account manifests (temp-02-*)
   - CRD manifests (temp-03-*)
   - Deployment manifests (temp-04-*)

## Platform Compatibility

This implementation automatically detects your operating system and uses appropriate commands:

- **Windows Systems**: Uses PowerShell commands with proper Windows path handling
- **Linux/Unix Systems**: Uses standard shell commands with Unix paths

For more details on platform-specific implementations, see `nirmata-platform-readme.md`.

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

See `nirmata-platform-readme.md` for instructions on using these backup files.

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