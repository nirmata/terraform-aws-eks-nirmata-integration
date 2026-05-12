#!/usr/bin/env bash
#
# apply-nirmata-controllers.sh
#
# Configure kubectl for an EKS cluster, fetch the Nirmata controller manifests
# via the Nirmata REST API, and apply them in the correct order to activate
# the cluster's registration with Nirmata.
#
# Run from a host that can reach BOTH:
#   - The Nirmata API endpoint (default https://nirmata.io)
#   - The EKS cluster's Kubernetes API server (e.g. via VPN, bastion, in-VPC runner)
#
# The TFE workspace is responsible only for creating the cluster and calling
# `nirmata_cluster_registered`. This script performs the post-provisioning
# step that TFE cannot do because it has no network path to the cluster.
#
# API paths used (verified against nirmata/terraform-provider-nirmata and
# nirmata/go-client source):
#   GET  <NIRMATA_URL>/cluster/api/KubernetesCluster?fields=id,name
#   GET  <NIRMATA_URL>/cluster/api/KubernetesCluster/<id>/controllerYAML
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
# Optional env vars:
#   NIRMATA_URL            Nirmata API base URL (default: https://nirmata.io)
#   NIRMATA_CLUSTER_NAME   Cluster name as registered in Nirmata
#                          (default: same as $1)
#   AWS_PROFILE            AWS CLI profile (default: default)
#   KUBECONFIG             Path to kubeconfig (default: ~/.kube/config)
#
# Usage:
#   export NIRMATA_TOKEN=xxxxxxxxxxxx
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
AWS_PROFILE="${AWS_PROFILE:-default}"

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

# List KubernetesCluster objects, filter by name in jq.
# (Using ?fields=id,name to keep the response small.)
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

# The endpoint returns JSON of the form {"<someKey>": "<full yaml string>"}.
# We download the JSON, then unwrap the YAML payload from the first value.
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
# Mirrors the provider's writeToTempDir() logic:
#   bucket 01 — Namespace
#   bucket 02 — ServiceAccount (but NOT lines like "- kind: ServiceAccount"
#               which appear inside RoleBinding subjects)
#   bucket 04 — Deployment
#   bucket 03 — everything else (CRDs, ClusterRoles, ConfigMaps, Secrets, ...)

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

# ─── 5. Apply each bucket in order with waits between phases ───────────────
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

apply_bucket "01-ns"     "namespaces"                     10
apply_bucket "02-sa"     "service accounts"               10
apply_bucket "03-other"  "CRDs / RBAC / config / network" 20
apply_bucket "04-deploy" "deployments"                     0

# ─── 6. Verify ─────────────────────────────────────────────────────────────
log "Verifying Nirmata namespace..."
if kubectl get ns nirmata >/dev/null 2>&1; then
  kubectl get pods -n nirmata
else
  log "Nirmata namespace not present yet — controllers may still be initializing."
fi

log "Done. Cluster '$CLUSTER_NAME' is registered with Nirmata."
log "Monitor with: kubectl get pods -n nirmata -w"
