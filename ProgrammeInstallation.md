# ProgrammeInstallation.md — Application installation and usage

## Deployment topology

The recorded K3s namespace is `vdi`. The observed application pods included:

| Workload | Purpose | Recorded state in captured snapshot |
|---|---|---|
| `cloudflared` | Cloudflare outbound tunnel connector | Running |
| `guacamole` | Browser remote desktop gateway | Running |
| `guacd` | RDP/VNC/SSH protocol proxy | Running |
| `postgres` | Guacamole database | Running |
| `guac-schema` | Guacamole DB schema initialization | Completed |
| `desktop-ravi01` | User desktop container | Running |
| `vdi-portal-web` | Admin portal frontend | Running |
| `vdi-portal-api` | Admin portal backend | Deployment created; earlier replica failure and readiness probe issue recorded; later pod started but readiness was still False in captured output |

Always verify current state before using the commands.

## Desktop image

Recorded image tags:
- `vdi-desktop:1.0`
- `vdi-desktop:1.2`
- `vdi-desktop:1.3`

The `1.3` image was built for ARM64:

```bash
cd ~/vdi/desktop-image
docker build --platform linux/arm64 -t vdi-desktop:1.3 .
docker save vdi-desktop:1.3 | sudo k3s ctr images import -
sudo k3s ctr images list | grep vdi-desktop
```

The build log and runtime checks recorded:
- XFCE desktop
- TigerVNC server, TCP `5901`
- Google Chrome
- Mozilla Firefox
- Visual Studio Code
- Google Antigravity IDE

Version checks inside the running desktop:

```bash
kubectl exec -n vdi deployment/desktop-ravi01 -- bash -c '
google-chrome-stable --version
firefox --version
ls -l /usr/bin/code
ls -l /usr/local/bin/antigravity
'
```

The desktop Deployment used `imagePullPolicy: Never`, so import the image into K3s containerd before starting/updating the pod.

## Desktop workspace resources

The terminal history shows `~/vdi/desktop-ravi01.yaml` defining:
- PVC `desktop-ravi01-home`
- Namespace `vdi`
- StorageClass `local-path`
- Requested storage `2Gi`
- Deployment `desktop-ravi01`
- One replica
- Container image `docker.io/library/vdi-desktop:1.3`
- User `ravi01`
- A VNC password sourced from a Kubernetes Secret (the exact secret value is not documented here)
- A Service named `desktop-ravi01` was applied

Apply the actual source YAML from the server after exporting it:

```bash
kubectl apply -f ~/vdi/desktop-ravi01.yaml
kubectl rollout status deployment/desktop-ravi01 -n vdi
kubectl get pods,svc,pvc -n vdi
kubectl logs deployment/desktop-ravi01 -n vdi
```

The captured desktop log reported TigerVNC starting on port `5901`. Do not expose VNC directly to the public Internet; use the intended authenticated browser gateway / protected tunnel route.

Resource limits applied to the desktop deployment:

```bash
kubectl set resources deployment/desktop-ravi01 \
  -n vdi \
  --requests=cpu=500m,memory=2Gi \
  --limits=cpu=2,memory=4Gi
```

## Guacamole / guacd / PostgreSQL

Recorded internal ports:
- Guacamole web service: `8080`
- guacd: `4822`
- PostgreSQL: `5432`

Recorded in-cluster Guacamole URL:

```text
http://guacamole.vdi.svc.cluster.local:8080
```

Inspect and operate:

```bash
kubectl get pods,svc,pvc,jobs -n vdi
kubectl logs deployment/guacamole -n vdi --tail=200
kubectl logs deployment/guacd -n vdi --tail=200
kubectl logs deployment/postgres -n vdi --tail=200
kubectl logs job/guac-schema -n vdi
```

The schema job was recorded as Completed and the database as having 23 tables. Do not rerun schema initialization against an existing database without reviewing the job and database state.

## VDI Admin Portal

Project folder recorded:

```text
~/vdi-admin-portal/phase1/
├── backend/
│   ├── Dockerfile
│   ├── requirements.txt
│   └── app/
└── k8s/
    ├── deployment.yaml
    └── rbac.yaml
```

The phase1 ZIP was extracted into a `phase1/` directory in the user's home. This is a partial tree based on captured terminal output; run the export script to collect the complete real tree.

Recorded API image:
`vdi-portal-api:0.1.0`

Recorded build and import commands:

```bash
cd ~/vdi-admin-portal/phase1
docker build --platform linux/arm64 -t vdi-portal-api:0.1.0 ./backend
docker save vdi-portal-api:0.1.0 | sudo k3s ctr images import -
```

Recorded API details:
- Container port `8000`
- Health path `/api/health`
- Secret reference `vdi-portal-auth`
- ServiceAccount `vdi-portal`
- Namespace `vdi`
- Deployment `vdi-portal-api`
- Service `vdi-portal-api`
- Image pull policy and exact Service port should be verified in the live YAML.

Recorded portal web resources:
- Deployment `vdi-portal-web`
- Service `vdi-portal-web`
- Pod observed Running
- Exact image, container port and Service port must be exported from live resources; do not guess.

Useful commands:

```bash
kubectl get deploy,svc,pods -n vdi
kubectl describe deployment vdi-portal-api -n vdi
kubectl logs deployment/vdi-portal-api -n vdi --tail=200
kubectl logs deployment/vdi-portal-web -n vdi --tail=200
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
```

A captured `describe deployment` showed `vdi-portal-api` `0/1` at one point, with liveness/readiness HTTP checks to `:8000/api/health`. Later terminal output showed a pod Running but `Ready: False`. Confirm the current health endpoint from inside the pod and inspect events before declaring the API healthy.

## Cloudflare Tunnel

A pod named like `cloudflared-...` was observed in namespace `vdi`. Inspect the actual Deployment name:

```bash
kubectl get deploy,pods -n vdi | grep cloudflared
kubectl logs deployment/cloudflared -n vdi --tail=200
```

The hostname and ingress origin should be read from the Cloudflare dashboard and live config. Do not store tunnel tokens or credential files in this guide or ZIP.

## Image archive restore

K3s uses containerd, separate from Docker's image store. Import a saved image archive:

```bash
sudo k3s ctr images import <image-archive.tar>
sudo k3s ctr images list
```

After importing, ensure the image reference in the Kubernetes Deployment exactly matches the imported image reference.

## Access and security

- Use Cloudflare Access or another approved identity gateway for public HTTPS entry.
- Keep PostgreSQL `5432`, guacd `4822` and raw VNC `5901` internal.
- Do not expose Kubernetes API `6443` publicly.
- Keep Kubernetes Secrets, Cloudflare tunnel tokens, passwords and kubeconfig private.
- Ensure `guacd` can reach the configured RDP/VNC/SSH target networks.
