# apply-nirmata-controllers.sh

Post-provisioning script that applies Nirmata controller manifests to an EKS
cluster from a network-reachable runner (laptop, bastion, in-VPC CI runner).

It exists because the TFE workspace that provisions the cluster runs on a
worker that **cannot reach the EKS private endpoint**. The workspace handles
infra + Nirmata registration only; this script does everything that needs
`kubectl` access to the cluster.

---

## What it does

1. Configures `kubectl` for the target EKS cluster via `aws eks update-kubeconfig`
2. Calls the Nirmata API to look up the cluster's internal ID by name
3. Downloads the controller manifest bundle from `GET /cluster/api/KubernetesCluster/<id>/controllerYAML`
4. Splits the bundle into four ordered buckets: namespaces → service accounts → CRDs/RBAC/config → deployments
5. (Optional) Rewrites `image:` lines in deployment manifests to point at a private-registry image
6. (Optional) Creates an `artifactory-secret` `docker-registry` secret in the `nirmata` namespace
7. (Optional) Patches every ServiceAccount in the `nirmata` namespace to use that secret as an `imagePullSecret`
8. Applies each bucket in order with waits in between, then prints pod status

---

## Prerequisites

| Tool       | Purpose                                  |
|------------|------------------------------------------|
| `aws` CLI  | EKS kubeconfig + IAM auth                |
| `kubectl`  | Apply manifests to the cluster           |
| `curl`     | Call the Nirmata REST API                |
| `jq`       | Parse JSON responses                     |

Network requirements:

- Outbound HTTPS to your Nirmata tenant (default `https://nirmata.io`)
- Inbound to the EKS API server (via VPN, bastion, or in-VPC runner)
- AWS credentials configured for the target cluster's account/region

---

## Inputs

### Positional arguments

| # | Name           | Description                                 |
|---|----------------|---------------------------------------------|
| 1 | `cluster_name` | EKS cluster name (matches `kubectl` context)|
| 2 | `aws_region`   | AWS region the cluster lives in             |

These come straight from your TFE workspace outputs (`cluster_name`, `aws_region`).

### Required env var

| Name            | Description           |
|-----------------|-----------------------|
| `NIRMATA_TOKEN` | Nirmata API token     |

### Optional Nirmata / AWS env vars

| Name                   | Default                | Description                                         |
|------------------------|------------------------|-----------------------------------------------------|
| `NIRMATA_URL`          | `https://nirmata.io`   | Nirmata tenant URL                                  |
| `NIRMATA_CLUSTER_NAME` | same as `$1`           | Cluster name as registered in Nirmata               |
| `NIRMATA_NAMESPACE`    | `nirmata`              | Namespace the controllers deploy into               |
| `AWS_PROFILE`          | `default`              | AWS CLI profile                                     |
| `KUBECONFIG`           | `~/.kube/config`       | Path to kubeconfig                                  |

### Optional image override

| Name    | Description                                                  |
|---------|--------------------------------------------------------------|
| `IMAGE` | If set, replaces **every** `image:` line in the downloaded deployment manifests with this value. Use this when you've mirrored the controller image into a private registry. |

> **Caveat:** the override is global across all deployments in the bundle. If Nirmata returns multiple deployments with distinct images (e.g. `kyverno` and `policy-reporter`), setting `IMAGE` will point them all at the same image — which would break things. In that case, leave `IMAGE` unset and configure a registry mirror in your container runtime instead.

### Optional private-registry pull secret

All three of these must be set together, or all left unset:

| Name              | Description                              |
|-------------------|------------------------------------------|
| `DOCKER_USERNAME` | Username for the private registry        |
| `DOCKER_PASSWORD` | Password / token                         |
| `DOCKER_SERVER`   | Registry server URL (e.g. `my.artifactory.com`) |

Tunables:

| Name                     | Default              | Description                       |
|--------------------------|----------------------|-----------------------------------|
| `DOCKER_EMAIL`           | empty                | Email address for the registry    |
| `IMAGE_PULL_SECRET_NAME` | `artifactory-secret` | Name of the secret to create      |

When these are set:

- A `docker-registry` secret named `${IMAGE_PULL_SECRET_NAME}` is created in `${NIRMATA_NAMESPACE}` (idempotent — re-running updates in place)
- Every ServiceAccount in `${NIRMATA_NAMESPACE}` is patched to use the secret as an `imagePullSecret` (strategic merge, won't duplicate)

---

## Usage

### Public registry (default Nirmata images, no pull secret)

```bash
export NIRMATA_TOKEN=xxxxxxxxxxxx
./apply-nirmata-controllers.sh my-eks-cluster us-west-2
```

### Private registry (image override + pull secret)

```bash
export NIRMATA_TOKEN=xxxxxxxxxxxx

# Image mirror in your artifactory
export IMAGE=my.artifactory.com/nirmata/kyverno:v1.13.2

# Credentials that the cluster will use to pull from artifactory
export DOCKER_USERNAME=svc-nirmata-pull
export DOCKER_PASSWORD=xxxxxxxxxxxx
export DOCKER_SERVER=my.artifactory.com

./apply-nirmata-controllers.sh my-eks-cluster us-west-2
```

### Non-default tenant + custom namespace + custom secret name

```bash
export NIRMATA_TOKEN=xxxxxxxxxxxx
export NIRMATA_URL=https://mycorp.nirmata.co
export NIRMATA_NAMESPACE=nirmata-system
export IMAGE_PULL_SECRET_NAME=mycorp-pull-creds

export DOCKER_USERNAME=...
export DOCKER_PASSWORD=...
export DOCKER_SERVER=...

./apply-nirmata-controllers.sh my-eks-cluster us-west-2
```

---

## Order of operations

```
1. apply 01-ns         (namespaces)              wait 10s
2. create artifactory-secret in nirmata ns       (if creds provided)
3. apply 02-sa         (service accounts)        wait 10s
4. patch each SA with imagePullSecrets           (if creds provided)
5. apply 03-other      (CRDs / RBAC / config)    wait 20s
6. apply 04-deploy     (deployments, IMAGE rewritten if set)
7. verify              (kubectl get pods -n nirmata)
```

Waits exist so that namespaces register, RBAC propagates, and CRDs become
available before objects that depend on them are applied.

---

## Verification

After the script finishes, controllers should come up in the `nirmata`
namespace:

```bash
kubectl get pods -n nirmata
kubectl get pods -n nirmata -w     # watch until Running
```

Confirm registration completed end-to-end by checking the Nirmata UI:
the cluster should move from `Pending` to `Ready`.

---

## Idempotency

Re-running the script is safe:

| Step               | Behavior on re-run                                          |
|--------------------|-------------------------------------------------------------|
| `kubectl apply -f` | Upsert — unchanged objects are no-ops                       |
| Pull secret create | `dry-run \| apply` — re-applies the same secret             |
| SA patch           | Strategic merge keyed on secret name — won't duplicate      |
| Image rewrite      | Operates on a fresh download each run                       |

You can re-run after rotating the docker password, after updating `IMAGE`,
or just to retry a partial failure.

---

## Troubleshooting

### `kubectl cluster-info` fails

You don't have network reachability to the EKS API server from this host.
Connect to your VPN / bastion / in-VPC runner first.

### `Cluster 'X' is not registered in Nirmata`

The TFE workspace hasn't run yet, or `nirmata_cluster_registered` failed.
Run the workspace first; the cluster only becomes lookable after that.

### `404` from the Nirmata API

Your tenant uses a non-default URL. Set `NIRMATA_URL` to your tenant
(e.g. `https://<tenant>.nirmata.co`). The script uses paths
`/cluster/api/KubernetesCluster` and `/cluster/api/KubernetesCluster/<id>/controllerYAML`.

### Pods stuck in `ImagePullBackOff`

The pull secret either wasn't created, wasn't attached to the ServiceAccount,
or has wrong credentials. Check:

```bash
kubectl -n nirmata get secret artifactory-secret -o yaml
kubectl -n nirmata get sa -o yaml | grep -A2 imagePullSecrets
kubectl -n nirmata describe pod <stuck-pod>     # shows the auth failure reason
```

### `command not found: jq` (or `aws`, `kubectl`, `curl`)

Install the missing tool, or fix your `PATH`. If `PATH` looks correct in
your interactive shell but the script can't find the tool, you're probably
running this from a non-login environment (cron, CI, systemd) — the script
inherits the parent process's PATH, not your `.zshrc`.

---

## How this fits in the workflow

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│  TFE workspace              │         │  Reachable runner            │
│  (no network to cluster)    │         │  (laptop / bastion / CI)     │
│                             │         │                              │
│  • module.eks               │         │  apply-nirmata-controllers.sh│
│  • nirmata_cluster_registered ─────►  │  • aws eks update-kubeconfig │
│  • exports cluster_name,    │ outputs │  • GET Nirmata API           │
│    aws_region, etc.         │         │  • kubectl apply manifests   │
└─────────────────────────────┘         │  • create artifactory-secret │
                                        │  • patch SAs                 │
                                        └──────────────────────────────┘
```

The TFE workspace owns the cluster lifecycle. This script owns the
configuration-as-code step that runs once after provisioning (and again
on rotations or upgrades). Keep the two concerns separate — don't add
`kubectl` calls back into the TFE workspace.
