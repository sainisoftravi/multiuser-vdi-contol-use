# K3s VDI / Self-hosted Workspace — Complete Export Kit

This kit is intended to collect the **real files and images from the Ubuntu K3s server** into one portable archive. It includes source-backed deployment notes, export scripts, restore instructions, and an inventory template.

## Critical distinction

This ZIP is an **export kit**, not a copy of the live server's entire filesystem or Docker image layers. The conversation records contain terminal history and selected snippets, not the full original `~/vdi`, `~/vdi-admin-portal`, YAML, Dockerfiles or image binaries. Those must be collected on the server using the scripts below.

Do not treat reconstructed/example YAML as the authoritative deployed configuration. Export the live resources and original project directories first.

## Recorded environment

- Host: `webserver`
- OS: Ubuntu 22.04.5 LTS
- Architecture: ARM64 / `aarch64`
- LAN address: `10.0.0.120`
- Kubernetes: K3s, namespace `vdi`
- Storage class: `local-path`
- Domain used in deployment notes: `labstackops.top`
- Recorded workloads: `cloudflared`, `desktop-ravi01`, `guacamole`, `guacd`, `postgres`, `guac-schema`, `vdi-portal-web`, `vdi-portal-api`
- Desktop image: `vdi-desktop:1.3` (ARM64)
- Portal API image: `vdi-portal-api:0.1.0` (ARM64)
- Portal API deployment was observed not Ready in an earlier snapshot; later pod became Running but readiness was still False in the captured describe output. Verify current status.

## Folder structure

```text
K3s-Complete-Export-Kit/
├── README.md
├── ProgrammeInstallation.md
├── source-records/
│   └── deployment-terminal-history-2026-11-20.txt
├── inventory/
│   └── recorded-images-and-endpoints.md
└── scripts/
    ├── collect-vdi-server.sh
    ├── export-docker-images.sh
    ├── export-k3s-images.sh
    ├── export-kubernetes-resources.sh
    └── restore-images-and-apply.sh
```

## 1. Run the full server collection

Copy this ZIP to the Ubuntu host, extract it, then:

```bash
unzip K3s-Complete-Export-Kit.zip
cd K3s-Complete-Export-Kit
chmod +x scripts/*.sh
sudo -v
./scripts/collect-vdi-server.sh
```

The collector writes an export directory under `$HOME/vdi-server-export-<timestamp>` and then creates a `.tar.gz` archive. It collects:

- Original project folders when present: `~/vdi`, `~/vdi-admin-portal`, `~/phase1`, `~/phase2`, `~/guac-workspace`, `~/workspaces`, `~/labstackops`
- YAML, Dockerfiles, shell scripts, Compose files and project source
- Kubernetes live resources in namespace `vdi` (Secrets are **not** exported with values)
- Cluster/node/pod/service/PVC/ingress/job/event information
- Docker image inventory and Docker container metadata
- K3s/containerd image inventory
- Host OS, architecture, disk, memory, network and listening-port summaries
- Cloudflared container/service status and logs where available

### Sensitive files

The collector excludes common secret files (`.env`, private keys, tunnel credential JSON, kubeconfigs, password files, `secrets*` and similar patterns) and does not dump Kubernetes Secret data. Review the export before sharing it. Application source code may itself contain hard-coded credentials; scan it before uploading or emailing.

### Important: image layers are a separate export

The full collector records image names and IDs but does not automatically save every image layer. Use the image export scripts separately because image archives can be many gigabytes.

## 2. Export Docker images

On the Ubuntu server:

```bash
./scripts/export-docker-images.sh
```

This exports all local Docker images into a timestamped archive using `docker save`. It may take substantial disk space. Check first:

```bash
docker images
docker system df
df -h
```

If you only want selected images, run:

```bash
docker save -o selected-docker-images.tar vdi-desktop:1.3 vdi-portal-api:0.1.0
```

Only include image names that actually appear in `docker images`.

## 3. Export images used by K3s/containerd

K3s does not use Docker's image store. `docker images` and `sudo k3s ctr images list` can therefore show different images.

```bash
./scripts/export-k3s-images.sh
```

This exports images from K3s containerd. The script checks available image references and writes a tar archive. It may be large; check disk space first.

## 4. Export current Kubernetes YAML

The collector exports non-secret Kubernetes objects in namespace `vdi` as YAML. It intentionally does not export Secret values. It also records Secret names/types and references.

To manually inspect live resources:

```bash
kubectl get all -n vdi -o wide
kubectl get deploy,sts,ds,svc,ingress,cm,sa,role,rolebinding,job,cronjob,pvc -n vdi -o yaml
kubectl get pv,storageclass -o yaml
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
```

The YAML from `kubectl get` is the live API representation. It may include generated fields such as `status`, `resourceVersion` and `uid`; review before reapplying it to another cluster.

## 5. Build Docker images and import them into K3s

Recorded desktop image build:

```bash
cd ~/vdi/desktop-image
docker build --platform linux/arm64 -t vdi-desktop:1.3 .
docker save vdi-desktop:1.3 | sudo k3s ctr images import -
sudo k3s ctr images list | grep vdi-desktop
```

Recorded portal API build:

```bash
cd ~/vdi-admin-portal/phase1
docker build --platform linux/arm64 -t vdi-portal-api:0.1.0 ./backend
docker save vdi-portal-api:0.1.0 | sudo k3s ctr images import -
sudo k3s ctr images list | grep vdi-portal-api
```

The desktop deployment used:

```yaml
image: docker.io/library/vdi-desktop:1.3
imagePullPolicy: Never
```

`imagePullPolicy: Never` requires the image to be present in K3s containerd under the exact image reference. Importing an image into Docker alone is not enough.

## 6. Restore on the same or a replacement K3s host

1. Install a compatible K3s version and prepare the namespace.
2. Transfer and extract the image archives.
3. Import images into K3s containerd.
4. Review manifests and replace environment-specific values.
5. Restore database data from a database backup (the PVC YAML alone does not contain the database contents).
6. Apply manifests in dependency order.
7. Verify pods, services, PVCs, endpoints, logs and Cloudflare tunnel.

Example:

```bash
sudo k3s ctr images import k3s-containerd-images-YYYYMMDD-HHMMSS.tar
kubectl create namespace vdi --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f <reviewed-configmaps-and-rbac>.yaml
kubectl apply -f <reviewed-pvc-and-database>.yaml
kubectl apply -f <reviewed-guacamole-and-guacd>.yaml
kubectl apply -f <reviewed-desktop-and-portal>.yaml
kubectl apply -f <reviewed-cloudflared>.yaml
kubectl get pods -n vdi -o wide
```

Do not apply exported Secret placeholders. Recreate secrets from a secure password manager or a separately protected backup.

## 7. Key commands

```bash
# Cluster and namespace
kubectl get nodes -o wide
kubectl get pods -n vdi -o wide
kubectl get deploy,svc,endpoints,pvc,jobs -n vdi

# Logs
kubectl logs -n vdi deployment/desktop-ravi01 --tail=200
kubectl logs -n vdi deployment/guacamole --tail=200
kubectl logs -n vdi deployment/guacd --tail=200
kubectl logs -n vdi deployment/postgres --tail=200
kubectl logs -n vdi deployment/vdi-portal-api --tail=200
kubectl logs -n vdi deployment/vdi-portal-web --tail=200

# Events and describe
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
kubectl describe pod <POD_NAME> -n vdi

# Docker and K3s image stores
docker images
docker ps -a
sudo k3s ctr images list

# K3s service logs
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 200 --no-pager
```

Deployment names may differ from the examples; check `kubectl get deployments -n vdi`.

## 8. Cloudflare Tunnel

A `cloudflared` pod was observed in namespace `vdi`. Check it with:

```bash
kubectl get pods -n vdi | grep cloudflared
kubectl logs -n vdi deployment/cloudflared --tail=200
kubectl describe deployment cloudflared -n vdi
```

If the actual deployment name differs, find it using:

```bash
kubectl get deployments -n vdi
```

Never include the tunnel token or credentials JSON in a shared archive. Use Cloudflare Zero Trust to verify the public hostname, tunnel connector health and Access policy. The tunnel's origin target must be reachable from the connector's network namespace.

## 9. What this package does not contain

- Actual Docker image binaries from the server. Run the image export scripts.
- The complete original project directories or every original YAML/Dockerfile. Run the collector on the server.
- PostgreSQL database contents. Make a database-aware backup separately.
- Cloudflare tunnel token/credentials or Kubernetes Secret values. These are deliberately excluded.
- A guarantee that every exported manifest can be applied unchanged to another machine. Review cluster-specific values and generated metadata.

