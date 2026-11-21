#!/usr/bin/env bash
set -Eeuo pipefail
NS="${1:-vdi}"
OUT="${2:-k8s-export-${NS}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUT"
for kind in deployments statefulsets daemonsets services ingress configmaps serviceaccounts roles rolebindings jobs cronjobs pvc; do
  kubectl get "$kind" -n "$NS" -o yaml > "$OUT/$kind.yaml" 2>"$OUT/$kind.err" || true
done
kubectl get pods -n "$NS" -o wide > "$OUT/pods.txt"
kubectl get events -n "$NS" --sort-by=.metadata.creationTimestamp > "$OUT/events.txt"
kubectl get endpoints,endpointslices -n "$NS" -o yaml > "$OUT/endpoints.yaml" 2>&1 || true
kubectl get secrets -n "$NS" -o custom-columns='NAME:.metadata.name,TYPE:.type' > "$OUT/secrets-inventory.txt"
kubectl get pv,storageclass -o yaml > "$OUT/storage.yaml"
echo "Exported non-secret resources to $OUT"
echo "Secret values were deliberately not exported."
