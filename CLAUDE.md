# CLAUDE.md

Podman image + launcher for running Claude Code, Snakemake and Jupyter on WSL2 with only the current project folder mounted. See `README.md` for user-facing setup; keep it in sync with any behaviour change.

## Files

- `Dockerfile`: `node:22-slim` + Miniforge (conda-forge only) + `@anthropic-ai/claude-code` via npm. `PATH` puts `/workspace/.conda_env/bin` first. `CLAUDE_CONFIG_DIR=/claude-config` (named volume holding the login).
- `entrypoint.sh`: runs inside the container on every start. Generates the per-project ed25519 key on first use (printing the public key), then Creates/updates `/workspace/.conda_env` from `/workspace/environment.yml`, then `exec "$@"`. A stamp file (`.conda_env/.environment.yml.stamp`) records the last successful create/update; a failed create removes the half-built env.
- `claude-box`: **runs on the host**, not in the container. Wraps `podman run -it --rm`, mounts `$PWD` → `/workspace`, the config volume → `/claude-config` and a per-project SSH volume → `/root/.ssh`. Also handles `pubkey` and `CLAUDE_BOX_GIT_NAME/EMAIL`. `claude-box jupyter` publishes `127.0.0.1:8888`.
- `environment.yml`: example/test project env. Per the README, real projects carry their own.

## Security model (do not weaken)

- The container sees only `/workspace` and `/claude-config`. No host SSH keys, git credentials, Windows drives or extra mounts. The only mounts are `$PWD`, the config volume and the per-project SSH volume (one key per project, used as a GitLab *deploy key*; never mount host `~/.ssh` or an agent socket). Don't add other `-v`, `--privileged`, host networking, or port bindings on `0.0.0.0`.
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

## Future work

Not yet done. Changes to `claude-box` and `Dockerfile` need the user's review (see trust boundary above).

0. **Untested:** the `Dockerfile` (new packages, git identity, ssh config) and the SSH key generation in `entrypoint.sh` could not be run from inside the container; verify after `podman build` that `git commit` and `claude-box pubkey` work.
1. **`claude-box` hardening**
   - The `$PWD` guard refuses only `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`. Extend it to every Windows drive and every path under it (`/mnt/[a-z]`, `/mnt/[a-z]/*`) and to ancestors of `$HOME` (e.g. `/home`).
   - `-it` fails when stdin isn't a TTY (scripts, pipes). Add `-t` only when `[ -t 0 ]`.
   - Consider `--cap-drop=ALL --security-opt=no-new-privileges` on `podman run`; check that conda env creation and npm still work.
2. **Reproducible `Dockerfile`**: pin Miniforge to a release instead of `latest`, and pin `@anthropic-ai/claude-code` (e.g. via a build arg). The Miniforge URL is hard-coded to x86_64; derive the architecture with `uname -m` if ARM support is wanted.
3. **Jupyter dependency**: `claude-box jupyter` needs `notebook` in the project's `environment.yml`; the base image has no Jupyter. At least document this in the README, or print a clear error when `jupyter` isn't on `PATH`.
