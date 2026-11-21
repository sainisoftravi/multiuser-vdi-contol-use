#!/usr/bin/env bash
set -Eeuo pipefail
command -v docker >/dev/null || { echo "Docker CLI not found"; exit 1; }
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${PWD}/docker-images-${TS}.tar"
echo "Images to export:"
docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' || true
echo
echo "Check free disk space before continuing:"
df -h .
read -r -p "Export ALL local Docker images? This may require many GB. Type YES: " answer
[[ "$answer" == "YES" ]] || { echo "Cancelled"; exit 0; }
mapfile -t IMAGES < <(docker images --format '{{.Repository}}:{{.Tag}}' | grep -v '<none>' | sort -u)
((${#IMAGES[@]})) || { echo "No tagged Docker images found"; exit 1; }
docker save -o "$OUT" "${IMAGES[@]}"
sha256sum "$OUT" > "$OUT.sha256"
echo "Created: $OUT"
echo "Restore with: docker load -i \"$OUT\""
