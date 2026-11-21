# Manifest directory

This folder is intentionally not populated with guessed manifests. The available source export contains terminal output and only a partial, corrupted display of `desktop-ravi01.yaml`; it does not contain complete source for all YAML and Dockerfiles.

The exact files referenced by the server deployment are listed in `../ProgrammeInstallation.md`, section 9. Export those original files from the server and add them here to create a fully reproducible source package.

Useful inspection commands on the server:

```bash
find ~/vdi ~/vdi-admin-portal ~/labstackops -type f \\
  \( -name '*.yaml' -o -name '*.yml' -o -name 'Dockerfile' -o -name 'docker-compose.yml' \) \\
  -print

kubectl get all -n vdi -o yaml > ~/vdi-live-resources.yaml
kubectl get pvc -n vdi -o yaml > ~/vdi-live-pvcs.yaml
kubectl get ingress -n vdi -o yaml > ~/vdi-live-ingress.yaml
```

`kubectl get ... -o yaml` exports live resource definitions but may include sensitive values or metadata. Review and sanitize before sharing. Kubernetes Secrets should not be exported into a general documentation ZIP.
