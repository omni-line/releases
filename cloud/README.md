# Omni Line cloud VM templates

Thin wrappers around the official [`install.sh`](../install.sh) / Compose stack. Each template provisions a single Linux VM, opens SSH + the app port, installs Docker, and runs the same installer used on any VPS.

| Cloud | Artifact | How to deploy |
|---|---|---|
| **AWS** | [`aws/cloudformation.yml`](aws/cloudformation.yml) | [Launch Stack](#aws) (CloudFormation) |
| **Azure** | [`azure/main.bicep`](azure/main.bicep) | [`az deployment`](#azure) |
| **DigitalOcean** | [`digitalocean/user-data.yaml`](digitalocean/user-data.yaml) | Droplet user-data / [doctl](digitalocean/droplet.md) |

Customer docs: https://omniline.app/docs/install/cloud  
Operator guide: [SELF_HOSTING.md](../../docs/ops/SELF_HOSTING.md)

**Not included:** Marketplace 1-Click images, multi-AZ / managed DB / object-storage wiring (use Compose overlays or Helm), Terraform modules.

Public raw URLs always come from [`omni-line/releases` `main`](https://github.com/omni-line/releases/tree/main/cloud) (synced from this tree on release).

## Shared bootstrap

[`cloud-init.sh`](cloud-init.sh) on a fresh Ubuntu/Debian host:

1. Skips if `/opt/omni-line/.env` exists (unless `OMNI_FORCE=1`)
2. Installs Docker Engine 25+ via `get.docker.com` when missing
3. Resolves `OMNI_URL` from env or AWS / Azure / DO metadata public IPv4
4. Runs `install.sh -y --dir /opt/omni-line --port … --url …`
5. Writes an SSH MOTD with the UI URL

```bash
# Manual / any VPS
curl -fsSL https://raw.githubusercontent.com/omni-line/releases/main/cloud/cloud-init.sh | bash
```

Optional env: `OMNI_URL`, `OMNI_PORT` (default `8080`), `OMNI_VERSION`, `OMNI_DIR`, `OMNI_FORCE=1`.

## AWS

[Launch Stack](https://console.aws.amazon.com/cloudformation/home#/stacks/CreateStack?stackName=omni-line&templateURL=https://raw.githubusercontent.com/omni-line/releases/main/cloud/aws/cloudformation.yml) (opens the AWS console; sign in, pick a region, set `KeyName` and optionally tighten `AllowedCidr`).

Or upload the template:

```bash
aws cloudformation create-stack \
  --stack-name omni-line \
  --template-url https://raw.githubusercontent.com/omni-line/releases/main/cloud/aws/cloudformation.yml \
  --parameters \
    ParameterKey=KeyName,ParameterValue=YOUR_KEY \
    ParameterKey=AllowedCidr,ParameterValue=203.0.113.0/24
```

Outputs include `PublicUrl` and `SshCommand`. First boot takes several minutes (Docker + image pull). Default size: `t3.medium`, Ubuntu 24.04, Elastic IP, ports 22 + 8080.

> CloudFormation `templateURL` must be reachable by AWS. If your account rejects GitHub raw URLs, download the YAML and use `--template-body file://cloudformation.yml` (or host it on S3).

## Azure

```bash
az group create -n omni-line-rg -l eastus

az deployment group create \
  -g omni-line-rg \
  -f main.bicep \
  -p adminPublicKey="$(cat ~/.ssh/id_ed25519.pub)" \
     allowedCidr=203.0.113.0/24
```

Use the published file:

```bash
curl -fsSL -O https://raw.githubusercontent.com/omni-line/releases/main/cloud/azure/main.bicep
```

Default size: `Standard_B2s`. Outputs: `publicUrl`, `sshCommand`.

## DigitalOcean

See [`digitalocean/droplet.md`](digitalocean/droplet.md). Short version:

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

Open TCP **22** and **8080** in a Cloud Firewall.

## After install

1. Open the `PublicUrl` / droplet IP on port 8080
2. Sign in with `BOOTSTRAP_ADMIN_*` from `/opt/omni-line/.env`
3. Activate your `OMNI-…` license under Settings → License
4. For production: put TLS in front, set `SERVER_URL` / `FRONTEND_URL` to HTTPS, prefer external Postgres + S3 overlays (Docker / Ansible docs)

## Limits

- Single-node Compose only (same as `install.sh`). Use Helm for multi-replica.
- Templates terminate nothing at HTTPS; use your edge or `overlays/tls-edge.compose.yml`.
- Marketplace AMI / 1-Click listings are out of scope for this tree.
