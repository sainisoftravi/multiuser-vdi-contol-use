#!/usr/bin/env bash
set -Eeuo pipefail

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${HOME}/vdi-server-export-${TS}"
mkdir -p "$OUT"/{host,kubernetes,projects,images,cloudflare,docker}

log(){ printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }

log "Export directory: $OUT"

# Host facts
{
  date -Is
  hostnamectl 2>&1 || true
  uname -a
  dpkg --print-architecture 2>&1 || true
  lsb_release -a 2>&1 || cat /etc/os-release
  free -h
  df -h
  ip -br address
  ip route
  sudo ss -lntup 2>&1 || ss -lntup 2>&1 || true
} > "$OUT/host/host-inventory.txt"

# Docker inventory, metadata and logs. No environment variable values are dumped.
if have docker; then
  docker version > "$OUT/docker/docker-version.txt" 2>&1 || true
  docker images --digests --no-trunc > "$OUT/docker/docker-images.txt" 2>&1 || true
  docker ps -a --no-trunc > "$OUT/docker/docker-containers.txt" 2>&1 || true
  docker network ls > "$OUT/docker/docker-networks.txt" 2>&1 || true
  docker volume ls > "$OUT/docker/docker-volumes.txt" 2>&1 || true
  while read -r id; do
    [ -n "$id" ] || continue
    docker inspect --format '{{.Name}} {{.Config.Image}} {{json .NetworkSettings.Ports}}' "$id" \
      >> "$OUT/docker/container-summary.txt" 2>/dev/null || true
  done < <(docker ps -aq)
  if docker ps -a --format '{{.Names}}' | grep -qx 'cloudflared-guac'; then
    docker logs --tail 500 cloudflared-guac > "$OUT/cloudflare/cloudflared-guac.log" 2>&1 || true
  fi
fi

# K3s and Kubernetes live inventory
if have kubectl; then
  kubectl version -o yaml > "$OUT/kubernetes/kubectl-version.yaml" 2>&1 || true
  kubectl get nodes -o wide > "$OUT/kubernetes/nodes.txt" 2>&1 || true
  kubectl get pods -A -o wide > "$OUT/kubernetes/pods-all-namespaces.txt" 2>&1 || true
  kubectl get all -n vdi -o wide > "$OUT/kubernetes/vdi-all.txt" 2>&1 || true
  kubectl get events -n vdi --sort-by=.metadata.creationTimestamp > "$OUT/kubernetes/vdi-events.txt" 2>&1 || true
  kubectl get pv,storageclass -o yaml > "$OUT/kubernetes/storage.yaml" 2>&1 || true
  # Export non-secret resources. Secret data is intentionally excluded.
  for kind in deployments statefulsets daemonsets services ingress configmaps serviceaccounts roles rolebindings jobs cronjobs pvc; do
    kubectl get "$kind" -n vdi -o yaml > "$OUT/kubernetes/${kind}.yaml" 2>"$OUT/kubernetes/${kind}.err" || true
  done
  kubectl get secrets -n vdi -o custom-columns='NAME:.metadata.name,TYPE:.type' \
    > "$OUT/kubernetes/secrets-inventory.txt" 2>&1 || true
  kubectl get endpoints,endpointslices -n vdi -o yaml > "$OUT/kubernetes/endpoints.yaml" 2>&1 || true
  kubectl get pods -n vdi -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.image}{" "}{end}{"\n"}{end}' \
    > "$OUT/images/k3s-pod-images.txt" 2>/dev/null || true
fi

if have sudo && sudo k3s --version >/dev/null 2>&1; then
  sudo k3s --version > "$OUT/host/k3s-version.txt" 2>&1 || true
  sudo systemctl status k3s --no-pager > "$OUT/host/k3s-service-status.txt" 2>&1 || true
  sudo journalctl -u k3s -n 500 --no-pager > "$OUT/host/k3s-journal.txt" 2>&1 || true
  sudo k3s ctr images list > "$OUT/images/k3s-containerd-images.txt" 2>&1 || true
fi

# Copy likely project directories. Exclude credentials, secrets and large runtime state.
copy_project(){
  local src="$1" name="$2"
  [ -d "$src" ] || return 0
  log "Copying project directory $src"
  mkdir -p "$OUT/projects/$name"
  rsync -a --prune-empty-dirs \
    --exclude='.git' \
    --exclude='node_modules' \
    --exclude='__pycache__' \
    --exclude='.venv' --exclude='venv' \
    --exclude='*.pyc' \
    --exclude='.env' --exclude='.env.*' \
    --exclude='*.pem' --exclude='*.key' --exclude='*.p12' --exclude='*.pfx' \
    --exclude='*credentials*.json' --exclude='*service-account*.json' \
    --exclude='*secret*' --exclude='secrets/' \
    --exclude='kubeconfig' --exclude='config.json' \
    --exclude='*.sqlite' --exclude='*.db' \
    --exclude='data/' --exclude='recordings/' \
    "$src/" "$OUT/projects/$name/" || true
}

copy_project "$HOME/vdi" "vdi"
copy_project "$HOME/vdi-admin-portal" "vdi-admin-portal"
copy_project "$HOME/phase1" "phase1"
copy_project "$HOME/phase2" "phase2"
copy_project "$HOME/guac-workspace" "guac-workspace"
copy_project "$HOME/workspaces" "workspaces"
copy_project "$HOME/labstackops" "labstackops"

# Copy known top-level manifests/scripts if present.
mkdir -p "$OUT/projects/home-files"
for f in "$HOME"/guacamole.yaml "$HOME"/postgres.yaml "$HOME"/cloudflared.yaml \
         "$HOME"/*.sh "$HOME"/*.yaml "$HOME"/*.yml; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  case "$base" in
    *secret*|*credential*|*.env*|*kubeconfig*|*.pem|*.key|*.json) continue ;;
  esac
  cp -n "$f" "$OUT/projects/home-files/" 2>/dev/null || true
done

# Generate searchable file inventory and checksums.
find "$OUT" -type f -printf '%P\t%s bytes\n' | sort > "$OUT/FILE-INVENTORY.tsv"
find "$OUT" -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > "$OUT/SHA256SUMS"

ARCHIVE="${OUT}.tar.gz"
tar -czf "$ARCHIVE" -C "$(dirname "$OUT")" "$(basename "$OUT")"
log "Finished. Archive: $ARCHIVE"
log "Review the archive for credentials/hard-coded secrets before sharing."
