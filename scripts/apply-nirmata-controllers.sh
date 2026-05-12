#!/usr/bin/env bash
#
# apply-nirmata-controllers.sh
#
# Configure kubectl for an EKS cluster, fetch the Nirmata controller manifests
# via the Nirmata REST API, optionally override container images with a
# private-registry image, create an image-pull secret for that registry,
# and apply everything in the correct order.
#
# Run from a host that can reach BOTH:
#   - The Nirmata API endpoint (default https://nirmata.io)
#   - The EKS cluster's Kubernetes API server (e.g. via VPN, bastion, in-VPC runner)
#
# API paths used (verified against nirmata/terraform-provider-nirmata and
# nirmata/go-client source):
#   GET <NIRMATA_URL>/cluster/api/KubernetesCluster?fields=id,name
#   GET <NIRMATA_URL>/cluster/api/KubernetesCluster/<id>/controllerYAML
# Auth header: Authorization: NIRMATA-API <token>
#
# ---------------------------------------------------------------------------
# Required positional args:
#   $1  cluster_name   — name of the EKS cluster
#   $2  aws_region     — AWS region of the EKS cluster
#
# Required env vars:
#   NIRMATA_TOKEN          Nirmata API token
#
# Optional Nirmata / AWS env vars:
#   NIRMATA_URL            Nirmata API base URL (default: https://nirmata.io)
#   NIRMATA_CLUSTER_NAME   Cluster name as registered in Nirmata (default: $1)
#   NIRMATA_NAMESPACE      K8s namespace controllers deploy into (default: nirmata)
#   AWS_PROFILE            AWS CLI profile (default: default)
#   KUBECONFIG             Path to kubeconfig (default: ~/.kube/config)
#
# Optional image-override env var:
#   IMAGE                  If set, replaces every `image:` line in the
#                          downloaded Deployment manifests with this value.
#                          Use this when you have mirrored the controller
#                          image into a private registry.
#
# Optional private-registry pull-secret env vars (all three or none):
#   DOCKER_USERNAME        Username for the private registry
#   DOCKER_PASSWORD        Password / token for the private registry
#   DOCKER_SERVER          Registry server URL (e.g. my.artifactory.com)
#
# Optional pull-secret tunables:
#   DOCKER_EMAIL              Email for the registry (default: empty)
#   IMAGE_PULL_SECRET_NAME    Secret name (default: artifactory-secret)
#
# Behaviour:
#   - If DOCKER_USERNAME, DOCKER_PASSWORD and DOCKER_SERVER are all set, the
#     script creates a docker-registry secret named ${IMAGE_PULL_SECRET_NAME}
#     in ${NIRMATA_NAMESPACE} and patches every ServiceAccount in that
#     namespace to use it as an imagePullSecret.
#   - The secret create is idempotent (dry-run | apply).
#   - The SA patch is idempotent (strategic merge keyed on secret name).
#
# Usage:
#   export NIRMATA_TOKEN=xxxxxxxxxxxx
#   export IMAGE=my.artifactory.com/nirmata/kyverno:v1.13.2
#   export DOCKER_USERNAME=svc-nirmata-pull
#   export DOCKER_PASSWORD=xxxxxxxxxxxx
#   export DOCKER_SERVER=my.artifactory.com
#   ./apply-nirmata-controllers.sh my-eks-cluster us-west-2
# ---------------------------------------------------------------------------

set -euo pipefail

# ─── Argument parsing ──────────────────────────────────────────────────────
if [[ $# -lt 2 ]]; then
  sed -n '2,/^# ---/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

CLUSTER_NAME="$1"
AWS_REGION="$2"

: "${NIRMATA_TOKEN:?NIRMATA_TOKEN environment variable must be set}"
NIRMATA_URL="${NIRMATA_URL:-https://nirmata.io}"
NIRMATA_URL="${NIRMATA_URL%/}"                          # strip trailing slash
NIRMATA_CLUSTER_NAME="${NIRMATA_CLUSTER_NAME:-$CLUSTER_NAME}"
NIRMATA_NAMESPACE="${NIRMATA_NAMESPACE:-nirmata}"
AWS_PROFILE="${AWS_PROFILE:-default}"

IMAGE="${IMAGE:-}"
IMAGE_PULL_SECRET_NAME="${IMAGE_PULL_SECRET_NAME:-artifactory-secret}"
DOCKER_USERNAME="${DOCKER_USERNAME:-}"
DOCKER_PASSWORD="${DOCKER_PASSWORD:-}"
DOCKER_SERVER="${DOCKER_SERVER:-}"
DOCKER_EMAIL="${DOCKER_EMAIL:-}"

CREATE_PULL_SECRET=false
if [[ -n "$DOCKER_USERNAME" || -n "$DOCKER_PASSWORD" || -n "$DOCKER_SERVER" ]]; then
  if [[ -z "$DOCKER_USERNAME" || -z "$DOCKER_PASSWORD" || -z "$DOCKER_SERVER" ]]; then
    echo "ERROR: DOCKER_USERNAME, DOCKER_PASSWORD and DOCKER_SERVER must all be set together (or all unset)." >&2
    exit 1
  fi
  CREATE_PULL_SECRET=true
fi

# ─── Dependency check ──────────────────────────────────────────────────────
for cmd in aws kubectl curl jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found in PATH" >&2
    exit 1
  fi
done

# ─── Working dir (auto-cleaned) ────────────────────────────────────────────
WORK_DIR="$(mktemp -d -t nirmata-XXXXXX)"
trap 'rm -rf "$WORK_DIR"' EXIT

log()  { printf '[%s] %s\n' "$(date +'%H:%M:%S')" "$*"; }
fail() { printf '[%s] ERROR: %s\n' "$(date +'%H:%M:%S')" "$*" >&2; exit 1; }

NIRMATA_AUTH_HEADER="Authorization: NIRMATA-API ${NIRMATA_TOKEN}"

# ─── 1. Configure kubectl for the EKS cluster ──────────────────────────────
log "Updating kubeconfig for EKS cluster '$CLUSTER_NAME' in region '$AWS_REGION'..."
aws eks update-kubeconfig \
  --region "$AWS_REGION" \
  --name   "$CLUSTER_NAME" \
  --profile "$AWS_PROFILE"

log "Verifying cluster connectivity..."
kubectl cluster-info >/dev/null \
  || fail "Cannot reach the EKS API server. Check VPN/bastion and security groups."

# ─── 2. Look up the cluster's Nirmata ID ───────────────────────────────────
log "Looking up '$NIRMATA_CLUSTER_NAME' in Nirmata at $NIRMATA_URL..."

CLUSTERS_JSON="$(curl -fsSL \
  -H "$NIRMATA_AUTH_HEADER" \
  -H "Accept: application/json" \
  "${NIRMATA_URL}/cluster/api/KubernetesCluster?fields=id,name")" \
  || fail "Failed to list clusters from Nirmata API. Check NIRMATA_TOKEN and NIRMATA_URL."

CLUSTER_ID="$(printf '%s' "$CLUSTERS_JSON" \
  | jq -r --arg name "$NIRMATA_CLUSTER_NAME" \
      '.[] | select(.name == $name) | .id' \
  | head -n 1)"

[[ -n "$CLUSTER_ID" ]] \
  || fail "Cluster '$NIRMATA_CLUSTER_NAME' is not registered in Nirmata.
         Run 'terraform apply' in the TFE workspace first so that
         nirmata_cluster_registered creates the cluster entry."

log "Found Nirmata cluster ID: $CLUSTER_ID"

# ─── 3. Download controller manifests from Nirmata ─────────────────────────
log "Downloading controller manifests from Nirmata..."

RAW_JSON="$WORK_DIR/controllers.json"
curl -fsSL \
  -H "$NIRMATA_AUTH_HEADER" \
  -H "Accept: application/json" \
  -o "$RAW_JSON" \
  "${NIRMATA_URL}/cluster/api/KubernetesCluster/${CLUSTER_ID}/controllerYAML" \
  || fail "Failed to download controllerYAML from Nirmata API."

MANIFEST_FILE="$WORK_DIR/controllers.yaml"
jq -r 'to_entries[0].value' "$RAW_JSON" > "$MANIFEST_FILE" \
  || fail "Failed to extract YAML from Nirmata API response."

[[ -s "$MANIFEST_FILE" ]] || fail "Extracted manifest is empty."
log "Got $(wc -l < "$MANIFEST_FILE" | tr -d ' ') lines of manifest data."

# ─── 4. Split into individual documents and classify by kind ───────────────
mkdir -p "$WORK_DIR/01-ns" "$WORK_DIR/02-sa" "$WORK_DIR/03-other" "$WORK_DIR/04-deploy"

awk -v OUT="$WORK_DIR" '
  BEGIN { idx = 0; buf = "" }
  /^---[[:space:]]*$/ {
    if (buf != "") { flush() }
    buf = ""; next
  }
  { buf = buf $0 "\n" }
  END { if (buf != "") flush() }

  function flush(   bucket, file) {
    if (buf ~ /^[[:space:]]*$/) { return }
    bucket = "03-other"
    if (buf ~ /(^|\n)kind:[[:space:]]+"?Namespace"?[[:space:]]*(\n|$)/) {
      bucket = "01-ns"
    } else if (buf ~ /(^|\n)kind:[[:space:]]+"?ServiceAccount"?[[:space:]]*(\n|$)/) {
      bucket = "02-sa"
    } else if (buf ~ /(^|\n)kind:[[:space:]]+"?Deployment"?[[:space:]]*(\n|$)/) {
      bucket = "04-deploy"
    }
    idx++
    file = sprintf("%s/%s/doc-%04d.yaml", OUT, bucket, idx)
    printf "%s", buf > file
    close(file)
    buf = ""
  }
' "$MANIFEST_FILE"

# ─── 4b. Override container image in deployment manifests (if requested) ───
if [[ -n "$IMAGE" ]]; then
  log "Overriding all container images in deployment manifests with: $IMAGE"
  shopt -s nullglob
  for f in "$WORK_DIR/04-deploy"/*.yaml; do
    # Match "image: ..." lines (any leading whitespace, optional quotes).
    # Preserve indentation; replace value with $IMAGE.
    sed -E -i.bak "s|^([[:space:]]*image:[[:space:]]*).+\$|\1${IMAGE}|" "$f"
    rm -f "$f.bak"
  done
  shopt -u nullglob
fi

# ─── Apply helpers ─────────────────────────────────────────────────────────
apply_bucket() {
  local bucket="$1"
  local label="$2"
  local wait_secs="$3"
  local files count=0

  shopt -s nullglob
  files=("$WORK_DIR/$bucket"/*.yaml)
  shopt -u nullglob

  if (( ${#files[@]} == 0 )); then
    log "No $label manifests to apply."
    return 0
  fi

  log "Applying $label (${#files[@]} document(s))..."
  for f in "${files[@]}"; do
    kubectl apply -f "$f"
    count=$((count + 1))
  done
  log "Applied $count $label resource(s)."

  if (( wait_secs > 0 )); then
    log "Waiting ${wait_secs}s for $label to settle..."
    sleep "$wait_secs"
  fi
}

create_pull_secret() {
  log "Creating image-pull secret '${IMAGE_PULL_SECRET_NAME}' in namespace '${NIRMATA_NAMESPACE}'..."
  # Build args carefully — email only included if non-empty
  local args=(
    create secret docker-registry "${IMAGE_PULL_SECRET_NAME}"
    --namespace="${NIRMATA_NAMESPACE}"
    --docker-server="${DOCKER_SERVER}"
    --docker-username="${DOCKER_USERNAME}"
    --docker-password="${DOCKER_PASSWORD}"
  )
  if [[ -n "$DOCKER_EMAIL" ]]; then
    args+=( --docker-email="${DOCKER_EMAIL}" )
  fi
  args+=( --dry-run=client -o yaml )

  # Idempotent: dry-run renders YAML, then apply upserts it
  kubectl "${args[@]}" | kubectl apply -f -
}

patch_service_accounts_with_pull_secret() {
  log "Patching ServiceAccounts in '${NIRMATA_NAMESPACE}' to reference '${IMAGE_PULL_SECRET_NAME}'..."
  local sa_names patch
  sa_names="$(kubectl -n "${NIRMATA_NAMESPACE}" get sa -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)"

  if [[ -z "$sa_names" ]]; then
    log "No ServiceAccounts found in '${NIRMATA_NAMESPACE}' to patch."
    return 0
  fi

  patch="$(printf '{"imagePullSecrets":[{"name":"%s"}]}' "${IMAGE_PULL_SECRET_NAME}")"
  for sa in $sa_names; do
    kubectl -n "${NIRMATA_NAMESPACE}" patch serviceaccount "$sa" \
      --type=strategic --patch "$patch" >/dev/null
    log "  patched serviceaccount/$sa"
  done
}

# ─── 5. Apply manifests in order, interleaving secret creation + SA patch ──

# 5a. Namespaces — must exist before secret/SA creation
apply_bucket "01-ns" "namespaces" 10

# 5b. Create pull secret (now that the namespace exists)
if [[ "$CREATE_PULL_SECRET" == "true" ]]; then
  create_pull_secret
fi

# 5c. ServiceAccounts
apply_bucket "02-sa" "service accounts" 10

# 5d. Patch each SA in the nirmata namespace so it carries the pull secret
if [[ "$CREATE_PULL_SECRET" == "true" ]]; then
  patch_service_accounts_with_pull_secret
fi

# 5e. CRDs / RBAC / config / network
apply_bucket "03-other" "CRDs / RBAC / config / network" 20

# 5f. Deployments (with image already overridden in step 4b if requested)
apply_bucket "04-deploy" "deployments" 0

# ─── 6. Verify ─────────────────────────────────────────────────────────────
log "Verifying namespace '${NIRMATA_NAMESPACE}'..."
if kubectl get ns "${NIRMATA_NAMESPACE}" >/dev/null 2>&1; then
  kubectl get pods -n "${NIRMATA_NAMESPACE}"
else
  log "Namespace '${NIRMATA_NAMESPACE}' not present yet — controllers may still be initializing."
fi

log "Done. Cluster '$CLUSTER_NAME' is registered with Nirmata."
log "Monitor with: kubectl get pods -n ${NIRMATA_NAMESPACE} -w"
