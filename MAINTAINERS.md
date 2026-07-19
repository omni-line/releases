# How this repo is updated

Source of truth for install files is the private monorepo (`deploy/install.sh`, `deploy/compose/`).

On each publish, the monorepo **Publish images** workflow:

1. Builds GHCR images from the monorepo  
2. Creates a GitHub Release **here** (`omni-line/releases`) with `install.sh`, `docker-compose.yml`, and `compose.env.example`

Required on the monorepo: secret `RELEASES_REPO_TOKEN` with write access to this repository.

Do not hand-edit release assets on a tag without also updating the monorepo `deploy/` tree for the next cut.
