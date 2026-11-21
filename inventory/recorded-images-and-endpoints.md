# Recorded image, application and endpoint inventory

This is based on the deployment terminal records, not a fresh query against the live host.

## Docker images recorded

| Image | Evidence |
|---|---|
| `vdi-desktop:1.0` | `docker images vdi-desktop` output |
| `vdi-desktop:1.2` | `docker images vdi-desktop` output |
| `vdi-desktop:1.3` | Built using `docker build --platform linux/arm64`; imported into K3s containerd |
| `vdi-portal-api:0.1.0` | Built using backend Dockerfile; imported into K3s containerd |

The actual image binaries are **not included**. Export them from the host using `scripts/export-docker-images.sh` and `scripts/export-k3s-images.sh`.

## Kubernetes workloads recorded

- `cloudflared` — pod observed Running
- `desktop-ravi01` — pod observed Running
- `guacamole` — pod observed Running
- `guacd` — pod observed Running
- `postgres` — pod observed Running
- `guac-schema` — job/pod observed Completed
- `vdi-portal-web` — pod observed Running
- `vdi-portal-api` — deployment and service created; captured status showed rollout/readiness problems at the time

## Recorded ports and endpoints

| Application | Port | Notes |
|---|---:|---|
| Guacamole | 8080 | In-cluster URL `http://guacamole.vdi.svc.cluster.local:8080` |
| guacd | 4822/TCP | Internal protocol proxy |
| PostgreSQL | 5432/TCP | Internal database |
| Desktop TigerVNC | 5901/TCP | Dockerfile `EXPOSE 5901`; do not expose publicly |
| VDI Portal API | 8000/TCP | Health endpoint `/api/health` |
| VDI Portal Web | Not established in captured snippet | Inspect live Service and Deployment |
| Cloudflare Tunnel | Outbound connector | Public hostname and origin must be checked in Cloudflare dashboard |

## Recorded desktop applications

- XFCE
- TigerVNC
- Google Chrome 158.0.8127.36 (recorded runtime output)
- Mozilla Firefox 160.0.1 (recorded runtime output)
- Visual Studio Code
- Google Antigravity IDE

## Recorded paths

- `~/vdi/desktop-image/`
- `~/vdi/desktop-ravi01.yaml`
- `~/vdi-admin-portal/phase1/`
- `~/phase1/k8s/rbac.yaml` (unzip output showed `phase1/k8s/rbac.yaml`)
- `~/phase1/k8s/deployment.yaml`
- `~/guacamole.yaml`
- `~/postgres.yaml`
- `~/cloudflared.yaml`

The last three files were listed in the home directory. Their complete contents were not present in the captured terminal text. Export the actual files from the host.
