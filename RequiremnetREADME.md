# K3s Self-Hosted Workspace / Browser Desktop Lab

## Deployment architecture, installation, operations and troubleshooting runbook

> **Purpose:** This README records the K3s deployment work and provides
> a repeatable operational guide for learning, maintenance and recovery.
>
> **Accuracy note:** The host details, K3s installation choices, cluster
> version, node state, PostgreSQL PVC, Guacamole/guacd services and
> schema-job result below are recorded from the deployment conversation.
> Some Cloudflare and application-routing steps were discussed as
> configuration/proposals rather than confirmed as completed. Those are
> labelled **configure/verify**. Replace placeholders such as
> `<YOUR_HOSTNAME>` with the actual values from the Cloudflare dashboard
> and manifests before running commands.

------------------------------------------------------------------------

## 1. What this deployment is for

The goal is to run a self-hosted browser-accessible workspace/desktop
service on one on-premises ARM64 Linux server.

A user connects to a hostname protected by Cloudflare. Cloudflare Tunnel
carries the HTTPS request back to the service inside the K3s cluster.
Guacamole provides the browser gateway; `guacd` brokers remote desktop
protocol connections; PostgreSQL stores Guacamole configuration and
connection data. Kubernetes runs and restarts the application containers
and provides service discovery and persistent storage.

This is a **single-node lab deployment**, not a highly available
production cluster.

### Main objectives

-   Run the workspace gateway and supporting services in K3s.
-   Keep the application services on internal Kubernetes `ClusterIP`
    services.
-   Avoid exposing application ports directly to the public Internet.
-   Use Cloudflare Tunnel rather than router port forwarding or a public
    inbound IP.
-   Store PostgreSQL data on a PersistentVolumeClaim.
-   Use Kubernetes RBAC/service accounts for controlled workspace
    management.
-   Learn the commands for installation, status, logs, troubleshooting
    and recovery.

------------------------------------------------------------------------

## 2. Recorded server and deployment facts

  -----------------------------------------------------------------------
  Item                                Recorded value
  ----------------------------------- -----------------------------------
  Operating system                    Ubuntu 22.04.5 LTS

  Architecture                        ARM64 / `aarch64`

  CPU                                 4 Neoverse-N1 vCPU

  Memory                              11 GiB RAM

  Swap                                4 GiB

  Root disk                           45 GB

  Server LAN IP                       `10.0.0.120`

  DNS domain used in the lab          `labstackops.top`

  Existing Cloudflare connector name  `cloudflared-guac`

  K3s version reported                `v1.37.2+k3s1`

  Kubernetes node name                `webserver`

  Container runtime                   containerd `2.3.7-k3s1`

  Kubeconfig path                     `/home/ubuntu/.kube/config`

  Default storage class               `local-path`

  K3s ingress / service load balancer Traefik and ServiceLB disabled at
                                      installation

  Existing Docker bridge networks     `172.17.0.0/16`, `172.19.0.0/16`
  -----------------------------------------------------------------------

**Important:** K3s is running on the same host that previously had
Docker workloads. K3s uses its own containerd runtime; `docker ps` does
not show K3s pods. Do not remove Docker networks, volumes, containers or
images as part of K3s maintenance unless you have separately verified
they are no longer required.

------------------------------------------------------------------------

## 3. Architecture

``` text
                   User browser
                        |
                        | HTTPS
                        v
             Cloudflare DNS / Proxy
                        |
                        v
              Cloudflare Tunnel
             connector: cloudflared-guac
                        |
                        | outbound tunnel connection
                        v
       +--------------------------------------+
       | Ubuntu 22.04.5 ARM64                 |
       | LAN: 10.0.0.120                      |
       |                                      |
       |  K3s single-node cluster             |
       |  Node: webserver                     |
       |                                      |
       |  Namespace: vdi                      |
       |                                      |
       |  +-------------------------------+   |
       |  | Service: guacamole            |   |
       |  | ClusterIP :8080               |   |
       |  |             |                 |   |
       |  |             v                 |   |
       |  | Guacamole web application     |   |
       |  +-------------------------------+   |
       |             |                        |
       |             | RDP/VNC/SSH brokering  |
       |             v                        |
       |  +-------------------------------+   |
       |  | Service: guacd                |   |
       |  | ClusterIP :4822               |   |
       |  | guacd daemon                  |   |
       |  +-------------------------------+   |
       |                                      |
       |  +-------------------------------+   |
       |  | Service: postgres             |   |
       |  | ClusterIP :5432               |   |
       |  | PostgreSQL pod                 |   |
       |  +-------------------------------+   |
       |             |                        |
       |             v                        |
       |  PVC: postgres-data (5Gi)            |
       |  StorageClass: local-path             |
       +--------------------------------------+

Remote desktop targets (RDP / VNC / SSH) are reached by guacd
according to the connection definitions configured in Guacamole.
```

### Component responsibilities

  -----------------------------------------------------------------------
  Component                           Purpose
  ----------------------------------- -----------------------------------
  Ubuntu host                         Physical/virtual machine hosting
                                      the cluster

  K3s                                 Lightweight Kubernetes distribution

  containerd                          Container runtime used by K3s

  `vdi` namespace                     Isolates workspace/Guacamole
                                      resources

  Guacamole                           Browser-based remote desktop
                                      gateway

  `guacd`                             Proxy daemon for RDP, VNC and SSH
                                      connections

  PostgreSQL                          Stores Guacamole users, connections
                                      and configuration

  `postgres-data` PVC                 Persistent storage claim for
                                      PostgreSQL

  `local-path`                        K3s local persistent-volume
                                      provisioner

  Cloudflare Tunnel                   Publishes the selected internal web
                                      service without inbound port
                                      forwarding

  Kubernetes Service                  Stable internal DNS name and port
                                      for each application
  -----------------------------------------------------------------------

### Network and security model

-   Public users should reach the application through Cloudflare HTTPS.
-   The Cloudflare connector makes an outbound connection to Cloudflare.
-   The Guacamole, guacd and PostgreSQL services were recorded as
    `ClusterIP`; they are not intended to be public LoadBalancer
    services.
-   PostgreSQL `5432` and guacd `4822` should remain internal.
-   Do not create public router port forwards for Kubernetes API `6443`,
    PostgreSQL `5432`, guacd `4822` or NodePort ranges.
-   Use Cloudflare Access policies/MFA for user authentication at the
    edge, in addition to application authentication.
-   A Cloudflare Tunnel is not a substitute for application
    authorization or Kubernetes RBAC.

------------------------------------------------------------------------

## 4. K3s installation

### 4.1 Pre-install checks

``` bash
uname -m
lsb_release -a
free -h
df -h
ip -br address
ip route
```

Expected architecture: `aarch64`.

Check Docker resources before changing anything:

``` bash
docker ps -a
docker network ls
docker volume ls
```

The deployment host had Docker bridge networks `172.17.0.0/16` and
`172.19.0.0/16`. Review for subnet overlap before adding custom
pod/service CIDRs.

### 4.2 Installation command used

Traefik and ServiceLB were disabled:

``` bash
curl -sfL https://get.k3s.io | \
  sudo INSTALL_K3S_EXEC="server --disable traefik --disable servicelb" sh -
```

Why disable them?

-   Traefik was disabled so that ingress/reverse-proxy routing could be
    chosen separately.
-   ServiceLB was disabled because the deployment is LAN-only and uses
    Cloudflare Tunnel rather than a public Kubernetes LoadBalancer.
-   K3s still provides the Kubernetes control plane, scheduler, kubelet,
    containerd and default local-path storage.

### 4.3 Configure kubectl for the ubuntu user

The recorded kubeconfig location is `/home/ubuntu/.kube/config`.

``` bash
mkdir -p "$HOME/.kube"
sudo cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
sudo chown "$USER":"$USER" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config"

export KUBECONFIG="$HOME/.kube/config"
```

To persist the environment variable:

``` bash
echo 'export KUBECONFIG=$HOME/.kube/config' >> ~/.bashrc
source ~/.bashrc
```

The kubeconfig copied from `/etc/rancher/k3s/k3s.yaml` normally uses
`127.0.0.1` as the API endpoint. That is appropriate for kubectl running
on the K3s server itself. Do not expose this admin kubeconfig to users
or copy it to untrusted machines.

### 4.4 Verify installation

``` bash
sudo systemctl status k3s --no-pager
sudo k3s --version
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
sudo k3s kubectl get storageclass
```

Recorded result:

-   K3s version: `v1.37.2+k3s1`
-   Node: `webserver`
-   Node status: `Ready`
-   Runtime: containerd `2.3.7-k3s1`
-   Storage class: `local-path`

### 4.5 K3s service operations

``` bash
sudo systemctl start k3s
sudo systemctl stop k3s
sudo systemctl restart k3s
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 100 --no-pager
sudo journalctl -u k3s -f
```

K3s server configuration and data locations:

``` bash
sudo cat /etc/rancher/k3s/config.yaml
sudo ls -lah /etc/rancher/k3s/
sudo ls -lah /var/lib/rancher/k3s/
```

Do not edit or delete files under `/var/lib/rancher/k3s` manually.

------------------------------------------------------------------------

## 5. Kubernetes everyday commands

Set the context for the current shell:

``` bash
export KUBECONFIG="$HOME/.kube/config"
alias k='kubectl'
```

If `kubectl` is not installed separately, use:

``` bash
sudo k3s kubectl get nodes
```

### Cluster overview

``` bash
kubectl cluster-info
kubectl get nodes -o wide
kubectl get namespaces
kubectl get pods -A -o wide
kubectl get deployments -A
kubectl get services -A
kubectl get storageclass
kubectl get pv
kubectl get pvc -A
kubectl get events -A --sort-by=.metadata.creationTimestamp
```

### Work in the VDI namespace

``` bash
kubectl get all -n vdi
kubectl get pods -n vdi -o wide
kubectl get deployments -n vdi
kubectl get services -n vdi
kubectl get pvc -n vdi
kubectl get pv
```

Recorded namespace: `vdi`.

### Describe a resource

``` bash
kubectl describe pod <POD_NAME> -n vdi
kubectl describe deployment <DEPLOYMENT_NAME> -n vdi
kubectl describe service <SERVICE_NAME> -n vdi
kubectl describe pvc <PVC_NAME> -n vdi
```

### Logs

``` bash
# List pods first
kubectl get pods -n vdi

# Current logs
kubectl logs <POD_NAME> -n vdi

# Follow live logs
kubectl logs -f <POD_NAME> -n vdi

# Previous container logs after a restart/crash
kubectl logs <POD_NAME> -n vdi --previous

# Logs for a particular container in a multi-container pod
kubectl logs <POD_NAME> -n vdi -c <CONTAINER_NAME>

# Logs from a deployment
kubectl logs deployment/<DEPLOYMENT_NAME> -n vdi --all-pods=true
```

### Watch and troubleshoot

``` bash
kubectl get pods -n vdi -w
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
kubectl describe pod <POD_NAME> -n vdi
kubectl top nodes
kubectl top pods -A
```

`kubectl top` requires Metrics Server to be available. If it reports
that Metrics API is unavailable, check the metrics-server deployment
before relying on those values.

### Execute a command inside a pod

``` bash
kubectl exec -it <POD_NAME> -n vdi -- sh
```

For a specific container:

``` bash
kubectl exec -it <POD_NAME> -n vdi -c <CONTAINER_NAME> -- sh
```

### Restart an application deployment

``` bash
kubectl rollout restart deployment/<DEPLOYMENT_NAME> -n vdi
kubectl rollout status deployment/<DEPLOYMENT_NAME> -n vdi
kubectl rollout history deployment/<DEPLOYMENT_NAME> -n vdi
```

### Apply and inspect manifests

``` bash
kubectl apply -f <FILE.yaml>
kubectl diff -f <FILE.yaml>
kubectl get -f <FILE.yaml> -n vdi
kubectl delete -f <FILE.yaml>
```

Use `kubectl delete` carefully; deleting a PVC can cause data loss
depending on the PV reclaim policy.

------------------------------------------------------------------------

## 6. Guacamole, guacd and PostgreSQL

### 6.1 Recorded deployment state

The following results were observed during deployment:

-   PostgreSQL pod was running in namespace `vdi`.
-   PVC `postgres-data` was `Bound`.
-   PVC capacity was `5Gi`.
-   Storage class was `local-path`.
-   The Guacamole schema initialization job completed.
-   The initialized database contained 23 tables.
-   Guacamole and guacd pods were subsequently running.
-   Services were internal `ClusterIP` services:
    -   Guacamole: port `8080`
    -   guacd: port `4822`
    -   PostgreSQL: port `5432`

Check the current state:

``` bash
kubectl get pods -n vdi -o wide
kubectl get svc -n vdi
kubectl get pvc -n vdi
kubectl get jobs -n vdi
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
```

### 6.2 Service DNS names

The recorded internal Guacamole service route was:

``` text
http://guacamole.vdi.svc.cluster.local:8080
```

Other expected service DNS names, if the Service resources use these
names, are:

``` text
guacd.vdi.svc.cluster.local:4822
postgres.vdi.svc.cluster.local:5432
```

Verify actual names before using them:

``` bash
kubectl get svc -n vdi
```

Kubernetes service DNS follows this pattern:

``` text
<SERVICE_NAME>.<NAMESPACE>.svc.cluster.local
```

### 6.3 Test service connectivity from inside the cluster

Start a temporary shell pod:

``` bash
kubectl run netcheck -n vdi --rm -it \
  --image=busybox:1.36 --restart=Never -- sh
```

Inside the shell, test DNS:

``` sh
nslookup guacamole.vdi.svc.cluster.local
nslookup guacd.vdi.svc.cluster.local
nslookup postgres.vdi.svc.cluster.local
```

Exit:

``` sh
exit
```

For HTTP testing, use a temporary curl-capable image if available:

``` bash
kubectl run curl-check -n vdi --rm -it \
  --image=curlimages/curl:latest --restart=Never -- \
  curl -I http://guacamole.vdi.svc.cluster.local:8080/
```

### 6.4 PostgreSQL persistence

Check the claim:

``` bash
kubectl get pvc postgres-data -n vdi
kubectl describe pvc postgres-data -n vdi
kubectl get pv
```

A `Bound` PVC means Kubernetes successfully matched the claim to a
volume. It does **not** mean a backup exists. Back up PostgreSQL data
separately.

Do not delete `postgres-data` to troubleshoot a web login or application
issue.

### 6.5 Database and schema troubleshooting

``` bash
kubectl get jobs -n vdi
kubectl describe jobs -n vdi
kubectl logs job/<SCHEMA_JOB_NAME> -n vdi
kubectl logs <POSTGRES_POD_NAME> -n vdi
```

The schema job was reported as `Completed` with 23 tables. If
redeploying, inspect the existing manifests and database state before
rerunning schema initialization. Reinitializing an existing database may
fail or damage data if done incorrectly.

------------------------------------------------------------------------

## 7. Cloudflare DNS and Tunnel

### 7.1 Why Cloudflare Tunnel is used

The server is on a private LAN at `10.0.0.120`. The design uses
Cloudflare Tunnel so the server establishes an outbound connection to
Cloudflare. This avoids exposing a home/office router port to the public
Internet.

Recorded domain: `labstackops.top`.

Recorded connector name: `cloudflared-guac`.

The exact public hostname and whether the connector is running as a
Docker container or system service must be checked in the actual
Cloudflare account and host. Do not assume a hostname from the connector
name.

### 7.2 Cloudflare dashboard configuration

In the Cloudflare Zero Trust dashboard:

1.  Open **Networks → Tunnels** (menu wording may vary).
2.  Find the existing tunnel/connector named `cloudflared-guac`.
3.  Confirm the connector status is **Healthy** or connected.
4.  Open the tunnel's **Public Hostnames** configuration.
5.  Add or verify the hostname, for example
    `<YOUR_HOSTNAME>.labstackops.top`.
6.  Set the service type to HTTP.
7.  Set the service URL to the internal Kubernetes service:

``` text
http://guacamole.vdi.svc.cluster.local:8080
```

8.  Save the route.
9.  Create or verify the Cloudflare Access application and policy for
    the hostname.
10. Require approved identities and MFA where appropriate.

**Network placement requirement:** The `cloudflared` connector must be
able to resolve and reach `guacamole.vdi.svc.cluster.local`. Kubernetes
service DNS names are normally resolvable only from inside the cluster.
If the connector is running as a Docker container or host service
outside the K3s pod network, the cluster DNS name may not resolve. In
that case, route the tunnel to a reachable LAN endpoint/reverse proxy,
or run the connector inside Kubernetes. Do not assume the service DNS
target works from an external Docker container.

### 7.3 Check an existing Docker-based connector

Because the connector was identified as `cloudflared-guac`, first check
whether it is a Docker container:

``` bash
docker ps -a --filter name=cloudflared-guac
docker logs --tail 100 cloudflared-guac
docker logs -f cloudflared-guac
docker inspect cloudflared-guac
```

Check all matching containers:

``` bash
docker ps -a | grep -i cloudflared
```

If it is not a Docker container, check systemd:

``` bash
sudo systemctl status cloudflared --no-pager
sudo journalctl -u cloudflared -n 100 --no-pager
sudo journalctl -u cloudflared -f
```

Do not install a second connector before identifying how the existing
`cloudflared-guac` connector is managed.

### 7.4 Install cloudflared on Ubuntu ARM64 (only if a host service is required)

This is an alternative installation path. Use it only if the existing
connector is not already running as a Docker container or Kubernetes
deployment.

Check architecture:

``` bash
dpkg --print-architecture
```

Expected: `arm64`.

Install using Cloudflare's package repository:

``` bash
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | \
  sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | \
  sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt-get update
sudo apt-get install -y cloudflared
cloudflared --version
```

Authenticate interactively:

``` bash
cloudflared tunnel login
```

Create a tunnel only if you are intentionally creating a new one:

``` bash
cloudflared tunnel create guac-tunnel
cloudflared tunnel list
```

A tunnel created by this command is not automatically the same as the
existing `cloudflared-guac` connector. Avoid creating duplicates.

For a named tunnel, configure the credentials file and
`/etc/cloudflared/config.yml` according to the tunnel UUID and the
selected route. Example template:

``` yaml
tunnel: <TUNNEL_UUID>
credentials-file: /etc/cloudflared/<TUNNEL_UUID>.json

ingress:
  - hostname: <YOUR_HOSTNAME>.labstackops.top
    service: http://<REACHABLE_INTERNAL_TARGET>:<PORT>
  - service: http_status:404
```

Validate and install as a service:

``` bash
sudo cloudflared tunnel ingress validate
sudo cloudflared service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared --no-pager
sudo journalctl -u cloudflared -f
```

The example `<REACHABLE_INTERNAL_TARGET>` must be reachable from the
connector's network namespace. Do not paste the Kubernetes-only DNS name
into a host-level connector config unless host DNS/network access to
that service has been deliberately configured.

### 7.5 Cloudflare tunnel diagnostics

``` bash
cloudflared tunnel list
cloudflared tunnel info <TUNNEL_NAME_OR_UUID>
cloudflared tunnel route dns list
```

For a system service:

``` bash
sudo journalctl -u cloudflared -n 200 --no-pager
sudo journalctl -u cloudflared -f
```

For Docker:

``` bash
docker logs --tail 200 cloudflared-guac
docker logs -f cloudflared-guac
```

Test public HTTPS:

``` bash
curl -I https://<YOUR_HOSTNAME>.labstackops.top
curl -v https://<YOUR_HOSTNAME>.labstackops.top
```

Interpret common results:

  -----------------------------------------------------------------------
  Result                              Likely meaning
  ----------------------------------- -----------------------------------
  `200` / `302`                       Application responds; redirect may
                                      be to login

  `403`                               Cloudflare Access or application
                                      authorization denied

  `404`                               Hostname reached a service, but
                                      requested path/route may not exist

  `502` / `503`                       Tunnel is connected but
                                      origin/service is unavailable or
                                      unreachable

  Cloudflare `1033`                   Tunnel/connector is not connected
                                      or route is unavailable

  DNS resolution failure              DNS record/hostname is missing or
                                      not propagated
  -----------------------------------------------------------------------

------------------------------------------------------------------------

## 8. Kubernetes RBAC and workspace permissions

RBAC controls what a service account or user can do through the
Kubernetes API. It does not automatically grant access to a Linux
desktop, RDP session or Cloudflare hostname.

The deployment work included a service account and an RBAC manifest
under:

``` text
~/phase2/k8s/rbac.yaml
```

The permissions shown in the working session included resource access
for services, secrets and persistent volume claims. The exact final
contents of that manifest are not reproduced here; inspect the live file
before changing it.

``` bash
cat ~/phase2/k8s/rbac.yaml
kubectl get serviceaccounts -A
kubectl get roles,rolebindings -A
kubectl get clusterroles,clusterrolebindings
```

Check the service account's permissions:

``` bash
kubectl auth can-i --list \
  --as=system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT> \
  -n <NAMESPACE>

kubectl auth can-i get pods \
  --as=system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT> \
  -n <NAMESPACE>

kubectl auth can-i create persistentvolumeclaims \
  --as=system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT> \
  -n <NAMESPACE>
```

Use namespace-scoped Roles and RoleBindings where possible. Avoid
granting `cluster-admin` to a workspace application unless there is a
specific, reviewed requirement. Keep secrets permissions as narrow as
possible.

### RBAC troubleshooting

``` bash
kubectl get sa -n <NAMESPACE>
kubectl describe sa <SERVICE_ACCOUNT> -n <NAMESPACE>
kubectl get role,rolebinding -n <NAMESPACE>
kubectl describe rolebinding <ROLEBINDING_NAME> -n <NAMESPACE>
kubectl auth can-i <VERB> <RESOURCE> \
  --as=system:serviceaccount:<NAMESPACE>:<SERVICE_ACCOUNT> \
  -n <NAMESPACE>
```

If a web UI says **Invalid**, inspect the browser's API response and the
backend logs. The issue may be an invalid token, incorrect service
account, wrong namespace, missing RBAC permission, or a malformed API
request. Do not solve it by granting broad permissions without checking
the denied API verb/resource.

------------------------------------------------------------------------

## 9. Storage and backup

The deployment uses K3s `local-path` storage. The PostgreSQL claim
recorded was `postgres-data`, size `5Gi`.

Inspect storage:

``` bash
kubectl get storageclass
kubectl get pv
kubectl get pvc -A
kubectl describe pvc postgres-data -n vdi
```

Find local-path provisioner pods:

``` bash
kubectl get pods -A | grep -i local-path
```

Check disk use:

``` bash
df -h
sudo du -sh /var/lib/rancher/k3s
sudo du -sh /var/lib/rancher/k3s/storage 2>/dev/null
```

### Backup principles

-   Back up PostgreSQL with a database-aware method such as
    `pg_dump`/`pg_dumpall`.
-   Keep a copy outside the same server.
-   Preserve Kubernetes manifests and Cloudflare tunnel
    configuration/credentials securely.
-   Do not publish tunnel credential JSON, kubeconfig, database
    passwords or Kubernetes Secret values in this README or source
    control.
-   Test a restore periodically.
-   A local-path volume is tied to local host storage; it is not high
    availability.

Example PostgreSQL logical backup command (adapt pod, database and user
names to the actual deployment):

``` bash
kubectl exec -n vdi <POSTGRES_POD_NAME> -- \
  pg_dump -U <DB_USER> -d <DB_NAME> \
  > postgres-backup-$(date +%F).sql
```

The command prompts/uses credentials according to the PostgreSQL
container configuration. Do not place passwords directly in shell
history.

------------------------------------------------------------------------

## 10. Common troubleshooting playbook

### A. Node is NotReady

``` bash
kubectl get nodes -o wide
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 200 --no-pager
df -h
free -h
```

Check disk pressure, memory pressure, service failures and container
runtime errors.

### B. Pod is Pending

``` bash
kubectl get pods -n vdi -o wide
kubectl describe pod <POD_NAME> -n vdi
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
kubectl get pvc -n vdi
```

Common causes: PVC not bound, insufficient CPU/RAM, node
selector/architecture mismatch, or image pull errors.

### C. Pod is CrashLoopBackOff

``` bash
kubectl describe pod <POD_NAME> -n vdi
kubectl logs <POD_NAME> -n vdi --previous
kubectl logs <POD_NAME> -n vdi
```

Check environment variables, secrets, database readiness, image
architecture and application startup logs.

### D. ImagePullBackOff

``` bash
kubectl describe pod <POD_NAME> -n vdi
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
```

Verify image name/tag, registry access, image pull secrets and ARM64
compatibility.

### E. Guacamole page does not open

``` bash
kubectl get pods,svc -n vdi -o wide
kubectl logs deployment/guacamole -n vdi --all-pods=true
kubectl logs deployment/guacd -n vdi --all-pods=true
kubectl logs deployment/postgres -n vdi --all-pods=true
```

Deployment names can differ; use `kubectl get deployments -n vdi` and
use the exact names returned.

Check internal service:

``` bash
kubectl get endpoints -n vdi
kubectl describe svc guacamole -n vdi
```

A Service with no endpoints generally means the pod selector does not
match ready pods.

### F. Guacamole cannot connect to guacd

Verify the guacd Service and port:

``` bash
kubectl get svc guacd -n vdi -o yaml
kubectl get endpoints guacd -n vdi
kubectl logs deployment/guacd -n vdi --all-pods=true
```

Check Guacamole's configured guacd hostname and port against the actual
service name and port.

### G. PostgreSQL connection failure

``` bash
kubectl get pods,pvc,svc -n vdi
kubectl logs <POSTGRES_POD_NAME> -n vdi
kubectl describe pod <POSTGRES_POD_NAME> -n vdi
kubectl describe pvc postgres-data -n vdi
```

Confirm database name, username, password secret reference, service name
and readiness. Never delete the PVC as a first troubleshooting step.

### H. Cloudflare error / 502

1.  Check connector status in Cloudflare Zero Trust.
2.  Inspect `cloudflared-guac` logs (Docker or systemd, depending on how
    it is installed).
3.  Verify the configured origin target is reachable from the connector.
4.  Verify the Guacamole service has ready endpoints.
5.  Check the route hostname and Cloudflare Access policy.

``` bash
kubectl get svc,endpoints -n vdi
kubectl get pods -n vdi -o wide
docker logs --tail 200 cloudflared-guac
```

Use the Docker command only if the connector is actually a Docker
container.

### I. ARM64 image compatibility

``` bash
uname -m
kubectl get pods -n vdi -o wide
kubectl describe pod <POD_NAME> -n vdi
```

Use container images that publish `linux/arm64` manifests, or build an
ARM64-compatible image. An AMD64-only image can fail on this ARM64 host.

### J. Check ports listening on the host

``` bash
sudo ss -lntup
```

Do not expose Kubernetes internal ports publicly just to make a pod
reachable through Cloudflare.

------------------------------------------------------------------------

## 11. Useful one-shot status report

Run this to capture the main cluster state:

``` bash
echo '===== HOST ====='
hostnamectl
uname -m
free -h
df -h

echo '===== K3S SERVICE ====='
sudo systemctl is-active k3s
sudo k3s --version

echo '===== NODES ====='
kubectl get nodes -o wide

echo '===== ALL PODS ====='
kubectl get pods -A -o wide

echo '===== VDI SERVICES ====='
kubectl get svc -n vdi

echo '===== VDI PVC ====='
kubectl get pvc -n vdi

echo '===== VDI JOBS ====='
kubectl get jobs -n vdi

echo '===== RECENT VDI EVENTS ====='
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp | tail -30

echo '===== CLOUDFLARED DOCKER CONTAINER (IF USED) ====='
docker ps -a --filter name=cloudflared-guac
```

Save output to a timestamped file:

``` bash
./cluster-status.sh 2>&1 | tee "cluster-status-$(date +%F-%H%M).log"
```

If using this command, first save the status commands above into
`cluster-status.sh` and make it executable:

``` bash
chmod +x cluster-status.sh
```

------------------------------------------------------------------------

## 12. Safe upgrade and maintenance checklist

Before upgrading K3s or application images:

1.  Record current versions and manifests.
2.  Verify free disk space and memory.
3.  Back up PostgreSQL.
4.  Back up the K3s configuration and application YAML.
5.  Confirm Cloudflare connector health.
6.  Upgrade one component at a time.
7.  Verify pods, services, endpoints and application login.
8.  Keep the previous image tag/manifests available for rollback.

Useful commands:

``` bash
kubectl get all -n vdi -o wide
kubectl get pvc -n vdi
kubectl get events -n vdi --sort-by=.metadata.creationTimestamp
sudo systemctl status k3s --no-pager
sudo journalctl -u k3s -n 100 --no-pager
```

Do not run `k3s-uninstall.sh`, delete `/var/lib/rancher/k3s`, or remove
PVCs as a routine troubleshooting step. These actions can destroy
cluster state or application data.

------------------------------------------------------------------------

## 13. Deployment inventory to complete

Fill in these values from the live system and Cloudflare dashboard. Do
not store passwords, API tokens, tunnel credentials or kubeconfig
contents here.

  ----------------------------------------------------------------------------
  Field                               Value to record
  ----------------------------------- ----------------------------------------
  Public Guacamole hostname           `<YOUR_HOSTNAME>.labstackops.top`

  Cloudflare tunnel UUID              `<TUNNEL_UUID>`

  Connector runtime                   Docker / systemd / Kubernetes

  Connector container or pod name     `cloudflared-guac` or actual name

  Kubernetes namespace                `vdi`

  Guacamole deployment name           Verify with `kubectl get deploy -n vdi`

  Guacamole service name/port         `guacamole:8080` (verify)

  guacd service name/port             `guacd:4822` (verify)

  PostgreSQL service name/port        `postgres:5432` (verify)

  PostgreSQL PVC                      `postgres-data`, 5Gi (recorded)

  Remote desktop target network       `<LAN/VPN network reachable by guacd>`

  Cloudflare Access policy            `<approved identity / MFA policy>`
  ----------------------------------------------------------------------------

------------------------------------------------------------------------

## 14. Key concepts to remember

-   **Pod:** Runs one or more containers.
-   **Deployment:** Maintains the desired number of application pods.
-   **Service:** Gives pods a stable network endpoint.
-   **ClusterIP:** Internal-only Kubernetes service address.
-   **Namespace:** Logical isolation boundary for Kubernetes resources.
-   **PVC:** A request for persistent storage.
-   **PV:** The storage resource backing a PVC.
-   **StorageClass:** Defines how persistent volumes are provisioned.
-   **ConfigMap:** Non-secret application configuration.
-   **Secret:** Sensitive configuration such as passwords and tokens.
-   **ServiceAccount:** Identity used by a pod/application when calling
    the Kubernetes API.
-   **Role/RoleBinding:** Grants namespace-scoped Kubernetes
    permissions.
-   **Cloudflare Tunnel:** Outbound connector that maps a public
    hostname to an internal origin.
-   **Guacamole:** Browser-based remote desktop gateway.
-   **guacd:** Remote desktop protocol proxy used by Guacamole.
-   **PostgreSQL:** Database for Guacamole's persistent configuration.

------------------------------------------------------------------------

## 15. Official documentation

-   K3s: https://docs.k3s.io/
-   K3s Quick Start: https://docs.k3s.io/quick-start
-   Kubernetes concepts: https://kubernetes.io/docs/concepts/
-   Kubernetes kubectl reference:
    https://kubernetes.io/docs/reference/kubectl/
-   Kubernetes RBAC:
    https://kubernetes.io/docs/reference/access-authn-authz/rbac/
-   Kubernetes persistent volumes:
    https://kubernetes.io/docs/concepts/storage/persistent-volumes/
-   Cloudflare Tunnel:
    https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
-   Cloudflare cloudflared:
    https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/
-   Apache Guacamole: https://guacamole.apache.org/doc/gug/
-   Apache Guacamole Docker:
    https://guacamole.apache.org/doc/gug/guacamole-docker.html

------------------------------------------------------------------------

## 16. Final operational reminder

This lab is a single ARM64 node with local-path storage. It is suitable
for learning and a controlled internal workspace service, but it has a
single point of failure: if the server or its local disk fails, the
cluster and local persistent data are unavailable until restored.

Keep database backups off-host, protect Cloudflare Access, keep
Kubernetes API credentials private, and verify the actual tunnel origin
network path before changing the public hostname route.
