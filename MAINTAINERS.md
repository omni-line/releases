# How this repo is updated

Source of truth for install files is the private monorepo (`deploy/install.sh`, `deploy/compose/`, `deploy/cloud/`, `deploy/ansible/`).

On each publish, the monorepo **Publish images** workflow:

1. Builds GHCR images from the monorepo  
2. Creates a GitHub Release **here** (`omni-line/releases`) with `install.sh`, compose assets, `overlays.tgz`, `cloud.tgz`, and the Ansible collection  
3. Syncs `install.sh` and `cloud/` onto this repository’s **`main`** branch (raw one-liner / Launch Stack URLs)

Required on the monorepo: secret `RELEASES_REPO_TOKEN` with write access to this repository.

Do not hand-edit release assets on a tag without also updating the monorepo `deploy/` tree for the next cut.
