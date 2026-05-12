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
# Optional per-deployment image overrides:
#   NIRMATA_KUBE_CONTROLLER_IMAGE  If set, replaces every `image:` line in
#                                  the Deployment whose metadata.name is
#                                  'nirmata-kube-controller'.
#   OTEL_AGENT_IMAGE               Same, for the Deployment whose
#                                  metadata.name is 'otel-agent'.
#
#   Each override is matched on metadata.name and only touches that one
#   Deployment manifest. Deployments without a matching override are left
#   untouched.
#
# Optional nirmata-kube-controller container-arg injection:
#   NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS
#       Space-separated args appended to the container's args list.
#       Example: '-insecure' to bypass TLS verification when the controller
#       cannot validate the certificate of a private endpoint.
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
#   export NIRMATA_KUBE_CONTROLLER_IMAGE=my.artifactory.com/nirmata/kube-controller:v1.x
#   export OTEL_AGENT_IMAGE=my.artifactory.com/nirmata/otel-agent:v0.y
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

# Per-deployment image overrides, keyed on metadata.name.
# Add more entries here if Nirmata introduces additional controllers.
declare -A IMAGE_OVERRIDES=()
[[ -n "${NIRMATA_KUBE_CONTROLLER_IMAGE:-}" ]] && IMAGE_OVERRIDES[nirmata-kube-controller]="$NIRMATA_KUBE_CONTROLLER_IMAGE"
[[ -n "${OTEL_AGENT_IMAGE:-}" ]]              && IMAGE_OVERRIDES[otel-agent]="$OTEL_AGENT_IMAGE"

# Extra container args to inject into the nirmata-kube-controller container.
# Space-separated. Useful for e.g. '-insecure' when the controller needs to
# bypass TLS verification against a private registry / Nirmata endpoint.
NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS="${NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS:-}"

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

# ─── 3a. Drop Nirmata's default registry Secret from the manifest ──────────
# Nirmata's bundle ships a kind:Secret named 'nirmata-controller-registry-secret'.
# We create our own image-pull secret (default name: artifactory-secret), so
# skip Nirmata's so we don't fight over the same object. References to the
# old name in SAs / Deployments are rewritten in step 3b below.
NIRMATA_DEFAULT_PULL_SECRET_NAME="nirmata-controller-registry-secret"
FILTERED_FILE="$WORK_DIR/controllers-filtered.yaml"

awk -v target_name="$NIRMATA_DEFAULT_PULL_SECRET_NAME" '
  BEGIN { buf = ""; first = 1; skipped = 0 }
  /^---[[:space:]]*$/ { flush(); buf = ""; next }
  { buf = buf $0 "\n" }
  END { flush(); printf "%d\n", skipped > "/dev/stderr" }

  function flush(   is_target_secret) {
    if (buf ~ /^[[:space:]]*$/) { return }
    is_target_secret = 0
    if (buf ~ /(^|\n)kind:[[:space:]]+"?Secret"?[[:space:]]*(\n|$)/) {
      # Only matches metadata.name at indent >=1 (Secrets have no nested name: keys)
      if (buf ~ ("(^|\n)[[:space:]]+name:[[:space:]]+\"?" target_name "\"?[[:space:]]*(\n|$)")) {
        is_target_secret = 1
      }
    }
    if (is_target_secret) { skipped++; return }
    if (!first) { printf "---\n" }
    first = 0
    printf "%s", buf
  }
' "$MANIFEST_FILE" > "$FILTERED_FILE" 2> "$WORK_DIR/skip-count.txt"

SKIPPED_SECRETS="$(cat "$WORK_DIR/skip-count.txt" 2>/dev/null || echo 0)"
if [[ "$SKIPPED_SECRETS" -gt 0 ]]; then
  log "Skipped ${SKIPPED_SECRETS} occurrence(s) of Secret '${NIRMATA_DEFAULT_PULL_SECRET_NAME}' from the downloaded manifest."
fi
mv "$FILTERED_FILE" "$MANIFEST_FILE"

# ─── 3b. Rewrite remaining references to the Nirmata-default secret name ──
# After 3a the kind:Secret object is gone, but SAs and Deployments still
# reference 'nirmata-controller-registry-secret' in their imagePullSecrets.
# Rewrite those references so they point to the secret we create below
# (default: artifactory-secret, configurable via IMAGE_PULL_SECRET_NAME).
if [[ "$IMAGE_PULL_SECRET_NAME" != "$NIRMATA_DEFAULT_PULL_SECRET_NAME" ]]; then
  log "Rewriting imagePullSecret '${NIRMATA_DEFAULT_PULL_SECRET_NAME}' → '${IMAGE_PULL_SECRET_NAME}' in remaining manifests..."
  sed -i.bak "s|${NIRMATA_DEFAULT_PULL_SECRET_NAME}|${IMAGE_PULL_SECRET_NAME}|g" "$MANIFEST_FILE"
  rm -f "${MANIFEST_FILE}.bak"
fi

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

# ─── 4b. Per-deployment image overrides ────────────────────────────────────
# For each Deployment YAML in 04-deploy/, extract its metadata.name and, if
# we have an override for it, rewrite every `image:` line in that file.
# Deployments with no matching override are left untouched.
extract_metadata_name() {
  # Reads a single-document Deployment YAML and prints metadata.name.
  # State machine: enter the top-level `metadata:` block, capture the first
  # `name:` key at deeper indentation, then exit. This avoids matching
  # `name:` keys nested under containers, ports, env, etc.
  awk '
    BEGIN { in_meta = 0 }
    /^metadata:[[:space:]]*$/                { in_meta = 1; next }
    in_meta && /^[^[:space:]]/               { in_meta = 0 }
    in_meta && /^[[:space:]]+name:[[:space:]]+/ {
      sub(/^[[:space:]]+name:[[:space:]]+/, "")
      gsub(/["'\'']/, "")
      sub(/[[:space:]]+$/, "")
      print
      exit
    }
  ' "$1"
}

if (( ${#IMAGE_OVERRIDES[@]} > 0 )); then
  log "Applying per-deployment image overrides..."
  declare -A SEEN=()
  shopt -s nullglob
  for f in "$WORK_DIR/04-deploy"/*.yaml; do
    dep_name="$(extract_metadata_name "$f")"
    if [[ -z "$dep_name" ]]; then
      log "  (skipping $f: could not determine metadata.name)"
      continue
    fi
    SEEN[$dep_name]=1
    if [[ -n "${IMAGE_OVERRIDES[$dep_name]:-}" ]]; then
      new_img="${IMAGE_OVERRIDES[$dep_name]}"
      log "  $dep_name → $new_img"
      sed -E -i.bak "s|^([[:space:]]*image:[[:space:]]*).+\$|\1${new_img}|" "$f"
      rm -f "$f.bak"
    else
      log "  $dep_name (no override; leaving image unchanged)"
    fi
  done
  shopt -u nullglob

  # Warn if any configured override didn't match a deployment (likely a typo).
  for k in "${!IMAGE_OVERRIDES[@]}"; do
    if [[ -z "${SEEN[$k]:-}" ]]; then
      log "  WARNING: override configured for '$k' but no Deployment with that metadata.name was found"
    fi
  done
fi

# ─── 4c. Inject extra args into nirmata-kube-controller container ──────────
# Useful for flags like '-insecure' that the controller needs to talk to a
# private endpoint with a self-signed or non-public-CA TLS certificate.
inject_container_args() {
  local file="$1"
  local extra_args="$2"
  local tmp="$file.tmp"

  awk -v EXTRA_ARGS_STR="$extra_args" '
    function get_indent(s) {
      match(s, /^[[:space:]]*/)
      return RLENGTH
    }
    BEGIN {
      state = "outside"
      n_extra = split(EXTRA_ARGS_STR, extra, /[[:space:]]+/)
      cleaned_n = 0
      for (i = 1; i <= n_extra; i++) {
        if (extra[i] != "") {
          cleaned_n++
          cleaned[cleaned_n] = extra[i]
        }
      }
    }
    {
      if ($0 ~ /^[[:space:]]*- name:[[:space:]]+/) {
        this_indent = get_indent($0)
        if ($0 ~ /^[[:space:]]*- name:[[:space:]]+nirmata-kube-controller[[:space:]]*$/) {
          if (state != "in-target" || this_indent <= container_indent) {
            state = "in-target"
            container_indent = this_indent
            print
            next
          }
        } else if (state == "in-target" && this_indent <= container_indent) {
          state = "outside"
        }
      }
      if (state == "in-target" && $0 ~ /^[[:space:]]+args:[[:space:]]*$/) {
        this_indent = get_indent($0)
        if (this_indent > container_indent) {
          print
          if ((getline next_line) > 0) {
            if (next_line ~ /^[[:space:]]+- /) {
              items_indent = get_indent(next_line)
            } else {
              items_indent = this_indent
            }
            for (i = 1; i <= cleaned_n; i++) {
              printf "%*s- %s\n", items_indent, "", cleaned[i]
            }
            print next_line
          }
          state = "done"
          next
        }
      }
      print
    }
    END {
      if (state == "in-target") {
        printf "WARNING: nirmata-kube-controller container has no args: section; skipped injecting [%s]\n", EXTRA_ARGS_STR > "/dev/stderr"
      }
    }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

if [[ -n "$NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS" ]]; then
  log "Injecting extra container args for nirmata-kube-controller: ${NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS}"
  shopt -s nullglob
  injected_any=0
  for f in "$WORK_DIR/04-deploy"/*.yaml; do
    dep_name="$(extract_metadata_name "$f")"
    if [[ "$dep_name" == "nirmata-kube-controller" ]]; then
      inject_container_args "$f" "$NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS"
      injected_any=1
    fi
  done
  shopt -u nullglob
  if (( injected_any == 0 )); then
    log "  WARNING: NIRMATA_KUBE_CONTROLLER_EXTRA_ARGS set but no nirmata-kube-controller Deployment was found"
  fi
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
