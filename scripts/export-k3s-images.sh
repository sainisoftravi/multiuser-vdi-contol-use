#!/usr/bin/env bash
set -Eeuo pipefail
command -v sudo >/dev/null
sudo k3s ctr images list >/dev/null
TS="$(date +%Y%m%d-%H%M%S)"
OUT="${PWD}/k3s-containerd-images-${TS}.tar"
echo "K3s/containerd images:"
sudo k3s ctr images list
echo
df -h .
read -r -p "Export ALL K3s containerd images? This may require many GB. Type YES: " answer
[[ "$answer" == "YES" ]] || { echo "Cancelled"; exit 0; }
mapfile -t REFS < <(sudo k3s ctr images list -q)
((${#REFS[@]})) || { echo "No K3s images found"; exit 1; }
sudo k3s ctr images export "$OUT" "${REFS[@]}"
sudo chown "$USER":"$USER" "$OUT"
sha256sum "$OUT" > "$OUT.sha256"
echo "Created: $OUT"
echo "Restore with: sudo k3s ctr images import \"$OUT\""
