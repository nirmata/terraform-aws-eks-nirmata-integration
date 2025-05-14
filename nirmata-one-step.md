# Nirmata Integration: One-Step Approach

We've implemented a one-step approach for the complete Nirmata integration using local-exec provisioners.

## How It Works

With a single terraform apply command, this configuration will:

1. Create the EKS cluster in AWS
2. Register the cluster with Nirmata
3. Automatically apply the Nirmata controller manifests using kubectl

## Usage

```bash
terraform init
terraform apply
```

## How We Solved the Dependency Challenge

Initially, this integration presented a challenge with Terraform:
- The controller manifests are only generated after the cluster is registered with Nirmata
- Terraform's `count` parameter can't depend on values that are only known after apply

We solved this by:
1. Using a `null_resource` with `local-exec` provisioners
2. Applying the controller manifests with kubectl commands
3. Adding appropriate depends_on to ensure proper sequencing
4. Adding sleep commands between steps to ensure resources are ready

## Manual Application (If Needed)

If for any reason the automatic controller deployment fails, you can manually apply the controllers:

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