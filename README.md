# Novartis EKS Cluster Terraform Configuration

This Terraform configuration creates a minimal EKS 1.32 cluster in the DevTest environment.

## Requirements

- Terraform >= 1.2.0
- AWS CLI configured with DevTest SSO profile (`devtest-sso`)
- AWS region set to `us-west-1`

## Resources Created

- Basic EKS Cluster version 1.32 (no add-ons or extra features)
- Minimal Node Group with 1 t3a.medium instance
- Security Group that:
  - Allows all traffic within the same SG
  - Allows inbound traffic on port 443 from VPN SG (sg-034c6b8a750d806ce)
- Required IAM roles and policies

## Infrastructure Details

- VPC: vpc-01a1c8d10eb2bb2ac (DevTest VPC in us-west-1)
- Subnets: subnet-04309b222eb8fd488, subnet-0dff3fad15acc9156
- EKS Version: 1.32
- Node Group: 1x t3a.medium instance
- Networking: Public endpoint only (private endpoint disabled)
- IAM: Using devtest-sso profile for authentication and authorization
- Configuration: Minimal setup with no logs or add-ons

## Usage

### Create EKS Cluster

1. Initialize Terraform:
   ```bash
   terraform init
   ```

2. Review the execution plan:
   ```bash
   terraform plan
   ```

3. Apply the configuration:
   ```bash
   terraform apply
   ```

4. Configure kubectl to access the cluster:
   ```bash
   aws eks update-kubeconfig --region us-west-1 --name novartis-eks-cluster --profile devtest-sso
   ```

5. Verify the cluster is running:
   ```bash
   kubectl get nodes
   ```

## Cleanup

To destroy all resources created by this configuration:

```bash
terraform destroy
```