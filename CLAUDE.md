# CLAUDE.md

Podman image + launcher for running Claude Code, Snakemake and Jupyter on WSL2 with only the current project folder mounted. See `README.md` for user-facing setup; keep it in sync with any behaviour change.

## Files

- `Dockerfile`: `node:22-slim` + Miniforge (conda-forge only) + `@anthropic-ai/claude-code` via npm. `PATH` puts `/workspace/.conda_env/bin` first. `CLAUDE_CONFIG_DIR=/claude-config` (named volume holding the login).
- `entrypoint.sh`: runs inside the container on every start. Creates/updates `/workspace/.conda_env` from `/workspace/environment.yml`, then `exec "$@"`. A stamp file (`.conda_env/.environment.yml.stamp`) records the last successful create/update; a failed create removes the half-built env.
- `claude-box`: **runs on the host**, not in the container. Wraps `podman run -it --rm`, mounts `$PWD` → `/workspace` and the config volume → `/claude-config`. `claude-box jupyter` publishes `127.0.0.1:8888`.
- `environment.yml`: example/test project env. Per the README, real projects carry their own.
- `.devcontainer/`: stale. References `docker-compose.yml` and `setup-env.sh`, neither of which exists, and the README advises against Dev Containers. Don't build on it.

## Security model (do not weaken)

- The container sees only `/workspace` and `/claude-config`. No SSH keys, git credentials, Windows drives or extra mounts. Don't add `-v`, `--privileged`, host networking, or port bindings on `0.0.0.0`.
- Ports bind to `127.0.0.1` only.
- Conda channels: `conda-forge` and `bioconda` only. Never add Anaconda `defaults` (ToS/licensing).
- Never set or rely on `ANTHROPIC_API_KEY`; auth is the Claude Team (BioFAIR) subscription login stored in the volume.
- Network is unrestricted. That's a documented limitation, not something to "fix" silently.
- **Trust boundary:** when this repo itself is the mounted `/workspace`, Claude can edit `claude-box`, which the user runs on the host (it's symlinked into `~/bin`). Treat changes to `claude-box` and `Dockerfile` as needing explicit user review. The README's intended layout keeps this repo outside any project folder.

## Working here

- You are likely running inside this image as root (rootless Podman maps that to the host user). `podman` isn't available in the container, so you cannot build or run the image; validate with `bash -n` and by running scripts against a temp copy (e.g. `sed` the `/workspace` paths to a scratch dir).
- Changes to `entrypoint.sh` or `Dockerfile` take effect only after the user rebuilds: `podman build -t claude-sandbox .`.
- Scripts use `set -euo pipefail` and bash arrays for argument lists; keep that style.
- `.conda_env/` and `*:Zone.Identifier` (Windows download metadata) are gitignored.

## Known follow-ups

- `Dockerfile`: Miniforge `latest` and Claude Code from npm are unpinned, so builds aren't reproducible. The Miniforge URL is hard-coded to x86_64.
- `claude-box`: refuses `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`, but not other drives (`/mnt/d`), `/mnt/c/` subfolders outside `Users`, or ancestors of `$HOME` (e.g. `/home`). `-it` fails when stdin isn't a TTY (scripts, pipes).
- `claude-box jupyter` needs `notebook` in the project's `environment.yml`; the base image has no Jupyter.
- Possible hardening: `--cap-drop=ALL --security-opt=no-new-privileges` on `podman run` (check that conda and npm still work).
