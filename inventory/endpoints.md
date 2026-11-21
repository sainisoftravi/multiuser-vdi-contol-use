# Application Endpoint Inventory

Only endpoints visible in the available deployment logs are recorded as confirmed. The actual current state must be checked with `kubectl get svc,endpoints -n vdi` and Cloudflare Tunnel Public Hostnames.

| App | Location | Port / Path | Notes |
|---|---|---|---|
| Guacamole | K3s `vdi` | `8080/TCP` | Internal browser gateway service; recorded in previous deployment notes. |
| guacd | K3s `vdi` | `4822/TCP` | Internal protocol proxy. |
| PostgreSQL | K3s `vdi` | `5432/TCP` | Internal database service. |
| VDI Portal API | K3s `vdi` | `8000/TCP`, `/api/health` | API container port and probe path seen in deployment describe output. At capture time readiness failed with connection refused. |
| VDI Portal Web | K3s `vdi` | Not captured | Service was created; exact port not included in terminal excerpt. |
| desktop-ravi01 | K3s `vdi` | `5901/TCP` image expose | Desktop image exposes VNC port; Kubernetes service/route must be verified. |
| Coder | Docker Compose | `10.0.0.120:7080` | Host port mapping observed in Compose status. |

## Live discovery commands

```bash
kubectl get svc,endpoints -n vdi -o wide
kubectl get ingress -n vdi -o wide
kubectl get deploy,pods -n vdi -o wide
```

Public hostnames must be copied from Cloudflare Zero Trust → Networks → Tunnels → the relevant tunnel → Public Hostnames. Do not infer public hostnames from internal service names.
