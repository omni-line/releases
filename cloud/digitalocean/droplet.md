# DigitalOcean Droplet (UI or doctl)

Omni Line does not ship a Marketplace 1-Click yet. Use Ubuntu 24.04 + this user-data so first boot installs Docker and runs the official `install.sh` (same stack as Docker Compose).

## Create in the control panel

1. Create → Droplets → **Ubuntu 24.04 LTS**.
2. Size: at least **2 vCPU / 4 GB RAM**, **40+ GB** disk.
3. Authentication: SSH key.
4. Advanced → **User data** → paste [`user-data.yaml`](user-data.yaml) (or download from [`releases`](https://raw.githubusercontent.com/omni-line/releases/main/cloud/digitalocean/user-data.yaml)).
5. Create a Cloud Firewall (or enable the Droplet firewall) allowing **TCP 22** and **TCP 8080** from your admin CIDR.
6. Wait ~3–8 minutes for cloud-init; then open `http://YOUR_DROPLET_IP:8080`.

Bootstrap admin credentials are in `/opt/omni-line/.env` (`BOOTSTRAP_ADMIN_*`). SSH MOTD also prints the URL.

## Create with doctl

```bash
curl -fsSL -o user-data.yaml \
  https://raw.githubusercontent.com/omni-line/releases/main/cloud/digitalocean/user-data.yaml

doctl compute droplet create omni-line \
  --region nyc3 \
  --image ubuntu-24-04-x64 \
  --size s-2vcpu-4gb \
  --ssh-keys YOUR_SSH_KEY_ID \
  --user-data-file user-data.yaml \
  --wait
```

Optional: set a custom origin before boot by editing `user-data.yaml` and uncommenting `export OMNI_URL=…`.

## After install

- Activate your `OMNI-…` license under Settings → License.
- For production HTTPS, terminate TLS at an edge proxy and set `SERVER_URL` / `FRONTEND_URL` (see [Docker Compose overlays](https://omniline.app/docs/install/docker)).
- Full cloud guide: https://omniline.app/docs/install/cloud
