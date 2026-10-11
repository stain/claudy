# CLAUDE.md

Podman image + launcher for running Claude Code, Snakemake and Jupyter on WSL2 with only the current project folder mounted. See `README.md` for user-facing setup; keep it in sync with any behaviour change.

## Files

- `Dockerfile`: fully qualified `docker.io/library/node:22-slim` (avoids Podman short-name prompts) + Miniforge (conda-forge only) + `@anthropic-ai/claude-code` via npm. Installs git, ssh client, curl/wget, jq, zip/unzip, patch, less, file, nano and build-essential. Sets default git identity via `GIT_AUTHOR_*`/`GIT_COMMITTER_*` `ENV` (`Claude Sandbox <claude-sandbox@localhost>`), marks `/workspace` as a git `safe.directory`, and writes `/etc/ssh/ssh_config.d/claude-box.conf` (only `~/.ssh/id_ed25519`, `IdentitiesOnly`, `StrictHostKeyChecking accept-new`). Build arg `WITH_PODMAN=1` (default 0) additionally installs podman, fuse-overlayfs, slirp4netns and uidmap plus `/etc/containers/*` config for the nested image `claude-sandbox-nested`. `PATH` puts `/workspace/.conda_env/bin` first. `CLAUDE_CONFIG_DIR=/claude-config` (named volume holding the login).
- `entrypoint.sh`: runs inside the container on every start. First generates the per-project ed25519 key in `/root/.ssh` if missing (printing the public key to stderr), then creates/updates `/workspace/.conda_env` from `/workspace/environment.yml`, then `exec "$@"`. A stamp file (`.conda_env/.environment.yml.stamp`) records the last successful create/update; a failed create removes the half-built env.
- `claude-box`: **runs on the host**, not in the container. Wraps `podman run -it --rm`, mounts `$PWD` → `/workspace`, the config volume → `/claude-config` and a per-project SSH volume → `/root/.ssh`. The SSH volume is named `claude-ssh-<folder>-<8-char sha256 of $PWD>` (override: `CLAUDE_BOX_SSH`), so moving or renaming a project folder gives it a new key. `claude-box pubkey` prints the public key; `CLAUDE_BOX_GIT_NAME`/`CLAUDE_BOX_GIT_EMAIL` override the image's git identity for one run. `claude-box jupyter` publishes `127.0.0.1:8888`. `CLAUDE_BOX_NESTED=1` is the only way `/dev/fuse` is passed (plus `label=disable` and a per-project `/var/lib/containers` volume) and selects the `claude-sandbox-nested` image; on WSL it refuses unless `/mnt/<drive>` 9p mounts and `WSLInterop` binfmt entries are absent (override `CLAUDE_BOX_ALLOW_UNSAFE_NESTED=1`, don't use it).
- `environment.yml`: example/test project env. Per the README, real projects carry their own.

## Security model (do not weaken)

- The container sees only `/workspace`, `/claude-config` and its own `/root/.ssh`. No host SSH keys, git credentials, Windows drives or extra mounts. The only mounts are `$PWD`, the config volume and the per-project SSH volume (one key per project, used as a GitLab *deploy key*; never mount host `~/.ssh` or an agent socket). Don't add other `-v`, `--privileged`, host networking, or port bindings on `0.0.0.0`.
- SSH keys are per project (one volume each) so containers can't cross-talk. Recommended use is a GitLab *deploy key* on a single repository, never a user-account key. The private key is readable by Claude; don't hide that in docs.
- **Nested mode is opt-in and off by default.** Never pass `/dev/fuse`, extra capabilities, `--privileged`, an unconfined seccomp profile or a host podman socket (a socket allows mounting any host path) in the default mode. In nested mode, pass only `/dev/fuse`. Don't remove the WSL check in `claude-box`: the intended deployment is a dedicated WSL distro with `[automount] enabled=false` and `[interop] enabled=false` (README "Dedicated WSL distro"), because an escape from a WSL2 container reaches the Windows files and programs of the user.
- Ports bind to `127.0.0.1` only.
- Conda channels: `conda-forge` and `bioconda` only. Never add Anaconda `defaults` (ToS/licensing).
- Never set or rely on `ANTHROPIC_API_KEY`; auth is the Claude Team (BioFAIR) subscription login stored in the volume.
- Network is unrestricted. That's a documented limitation, not something to "fix" silently.
- **Trust boundary:** when this repo itself is the mounted `/workspace`, Claude can edit `claude-box`, which the user runs on the host (it's symlinked into `~/bin`). Treat changes to `claude-box` and `Dockerfile` as needing explicit user review. The README's intended layout keeps this repo outside any project folder.

## Working here

- You are likely running inside this image as root (rootless Podman maps that to the host user). `podman` isn't available in the container, so you cannot build or run the image; validate with `bash -n` and by running scripts against a temp copy (e.g. `sed` the `/workspace` paths to a scratch dir).
- Changes to `entrypoint.sh` or `Dockerfile` take effect only after the user rebuilds: `podman build -t claude-sandbox .`.
- Git commits from the container use the env-var identity above; don't write a host `~/.gitconfig` or credentials into the image or volumes.
- Scripts use `set -euo pipefail` and bash arrays for argument lists; keep that style.
- `.conda_env/` and `*:Zone.Identifier` (Windows download metadata) are gitignored.

## Future work

Not yet done. Changes to `claude-box` and `Dockerfile` need the user's review (see trust boundary above).

0. **Nested mode is unverified.** Build `--build-arg WITH_PODMAN=1`, run `CLAUDE_BOX_NESTED=1 claude-box bash`, then `podman run --rm docker.io/library/hello-world` inside. If it fails with permission or mount errors, work out the *minimum* extra option (seccomp, a non-root inner user with subuid ranges, `/dev/net/tun`) and record it here; do not reach for `--privileged`. The WSL checks in `claude-box` and the `wsl.conf` in the README also need a test on a real distro (`ls /mnt/c`, `cmd.exe`, nested refusal on the normal distro).
0. **Verify after first rebuild:** the new `Dockerfile` packages, git identity, ssh config, per-project key generation and `claude-box pubkey` were written without being built or run (no `podman` in the container). Check `podman build` succeeds, `git commit` works with the default author, `claude-box pubkey` prints a key, `ssh -T git@gitlab.com` authenticates with a deploy key, and a second project folder gets a different key.
1. **`claude-box` hardening**
   - The `$PWD` guard refuses only `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`. Extend it to every Windows drive and every path under it (`/mnt/[a-z]`, `/mnt/[a-z]/*`) and to ancestors of `$HOME` (e.g. `/home`).
   - `-it` fails when stdin isn't a TTY (scripts, pipes). Add `-t` only when `[ -t 0 ]`.
   - Consider `--cap-drop=ALL --security-opt=no-new-privileges` on `podman run`; check that conda env creation and npm still work.
2. **Reproducible `Dockerfile`**: pin Miniforge to a release instead of `latest`, and pin `@anthropic-ai/claude-code` (e.g. via a build arg). The Miniforge URL is hard-coded to x86_64; derive the architecture with `uname -m` if ARM support is wanted.
3. **Jupyter dependency**: `claude-box jupyter` needs `notebook` in the project's `environment.yml`; the base image has no Jupyter. At least document this in the README, or print a clear error when `jupyter` isn't on `PATH`.
