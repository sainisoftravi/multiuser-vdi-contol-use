#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <k3s-image-archive.tar> [manifest-directory]"
  exit 2
fi
IMAGE_ARCHIVE="$1"
MANIFEST_DIR="${2:-}"
[[ -f "$IMAGE_ARCHIVE" ]] || { echo "Image archive not found: $IMAGE_ARCHIVE"; exit 1; }
sudo k3s ctr images import "$IMAGE_ARCHIVE"
sudo k3s ctr images list
if [[ -n "$MANIFEST_DIR" ]]; then
  echo "Review YAML and recreate secrets before applying."
  echo "This script intentionally does not blindly apply the manifest directory."
  echo "Apply reviewed files in dependency order, then verify:"
  echo "kubectl get pods,svc,pvc -n vdi -o wide"
fi
