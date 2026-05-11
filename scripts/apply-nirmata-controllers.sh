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
# ---------------------------------------------------------------------------
# Required positional args:
#   $1  cluster_name   — name of the EKS cluster (and the Nirmata cluster name
#                        unless NIRMATA_CLUSTER_NAME is set)
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
  sed -n '2,/^---/p' "$0" | sed 's/^# \{0,1\}//'
  exit 1
fi

CLUSTER_NAME="$1"
AWS_REGION="$2"

: "${NIRMATA_TOKEN:?NIRMATA_TOKEN environment variable must be set}"
NIRMATA_URL="${NIRMATA_URL:-https://nirmata.io}"
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

# Nirmata's auth header: 'Authorization: NIRMATA-API <token>'
NIRMATA_AUTH_HEADER="Authorization: NIRMATA-API ${NIRMATA_TOKEN}"

# List registered clusters and filter by name.
# Endpoint path may vary slightly by Nirmata version; this is the v3 path.
CLUSTERS_JSON="$(curl -fsSL \
  -H "$NIRMATA_AUTH_HEADER" \
  -H "Accept: application/json" \
  "${NIRMATA_URL}/environments/api/ClusterRegistered?fields=id,name")" \
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

# Endpoint that returns the controller YAML bundle (multi-document YAML)
MANIFEST_FILE="$WORK_DIR/controllers.yaml"
curl -fsSL \
  -H "$NIRMATA_AUTH_HEADER" \
  -H "Accept: application/yaml" \
  -o "$MANIFEST_FILE" \
  "${NIRMATA_URL}/environments/api/ClusterRegistered/${CLUSTER_ID}/clusterControllerYamls" \
  || fail "Failed to download controller manifests from Nirmata API."

[[ -s "$MANIFEST_FILE" ]] \
  || fail "Downloaded manifest is empty."

log "Downloaded $(wc -l < "$MANIFEST_FILE" | tr -d ' ') lines of manifest data."

# Split the multi-document YAML into individual docs so we can apply in order.
# Most kubectl versions accept the combined file, but ordering matters here:
# Nirmata returns Namespaces, RBAC, CRDs, then workloads. We split + classify.
csplit -z -s -f "$WORK_DIR/doc-" -b "%04d.yaml" "$MANIFEST_FILE" '/^---[[:space:]]*$/' '{*}' || true

DOC_COUNT="$(ls -1 "$WORK_DIR"/doc-*.yaml 2>/dev/null | wc -l | tr -d ' ')"
log "Split into $DOC_COUNT individual manifest documents."

# ─── 4. Apply manifests in dependency order ────────────────────────────────
apply_kinds() {
  local kind_regex="$1"   # extended-regex matching the kind: value
  local label="$2"
  local wait_secs="$3"
  local applied=0

  log "Applying ${label}..."
  for f in "$WORK_DIR"/doc-*.yaml; do
    [[ -s "$f" ]] || continue
    if grep -qE "^kind:[[:space:]]+(${kind_regex})\b" "$f"; then
      kubectl apply -f "$f"
      applied=$((applied + 1))
    fi
  done
  log "Applied ${applied} ${label} resource(s)."

  if (( wait_secs > 0 )) && (( applied > 0 )); then
    log "Waiting ${wait_secs}s for ${label} to settle..."
    sleep "$wait_secs"
  fi
}

apply_kinds "Namespace"                                                "namespaces" 10
apply_kinds "ServiceAccount|ClusterRole|ClusterRoleBinding|Role|RoleBinding" "RBAC"       10
apply_kinds "CustomResourceDefinition"                                 "CRDs"       20
apply_kinds "ConfigMap|Secret|Service"                                 "config & networking" 5
apply_kinds "Deployment|DaemonSet|StatefulSet|Job|CronJob"             "workloads"  0

# Catch anything not matched above (custom kinds defined by the CRDs we just applied)
log "Applying any remaining manifests..."
remaining=0
for f in "$WORK_DIR"/doc-*.yaml; do
  [[ -s "$f" ]] || continue
  KIND="$(grep -E '^kind:[[:space:]]+' "$f" | head -n 1 | awk '{print $2}')"
  case "$KIND" in
    Namespace|ServiceAccount|ClusterRole|ClusterRoleBinding|Role|RoleBinding| \
    CustomResourceDefinition|ConfigMap|Secret|Service| \
    Deployment|DaemonSet|StatefulSet|Job|CronJob) ;;  # already applied
    "") ;;                                            # empty/malformed doc
    *)  kubectl apply -f "$f"; remaining=$((remaining + 1)) ;;
  esac
done
log "Applied ${remaining} additional resource(s) (custom kinds)."

# ─── 5. Verify ─────────────────────────────────────────────────────────────
log "Verifying Nirmata namespace..."
if kubectl get ns nirmata >/dev/null 2>&1; then
  kubectl get pods -n nirmata
else
  log "Nirmata namespace not present yet — controllers may still be initializing."
fi

log "Done. Cluster '$CLUSTER_NAME' is registered with Nirmata."
log "Monitor with: kubectl get pods -n nirmata -w"
