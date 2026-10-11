# CLAUDE.md

Podman image + launcher for running Claude Code, Snakemake and Jupyter on WSL2 with only the current project folder mounted. See `README.md` for user-facing setup; keep it in sync with any behaviour change.

## Files

- `Dockerfile`: fully qualified `docker.io/library/node:22-slim` (avoids Podman short-name prompts) + Miniforge (conda-forge only) + `@anthropic-ai/claude-code` via npm. Installs git, ssh client, curl/wget, jq, zip/unzip, patch, less, file, nano and build-essential. Sets default git identity via `GIT_AUTHOR_*`/`GIT_COMMITTER_*` `ENV` (`Claude Sandbox <claude-sandbox@localhost>`), marks `/workspace` as a git `safe.directory`, and writes `/etc/ssh/ssh_config.d/claudy.conf` (only `~/.ssh/id_ed25519`, `IdentitiesOnly`, `StrictHostKeyChecking accept-new`). Build arg `WITH_PODMAN=1` (default 0) additionally installs podman, fuse-overlayfs, slirp4netns and uidmap plus `/etc/containers/*` config for the nested image `claudy-nested`. `PATH` puts `/workspace/.conda_env/bin` first. `CLAUDE_CONFIG_DIR=/claude-config` (named volume holding the login).
- `entrypoint.sh`: runs inside the container on every start. First generates the per-project ed25519 key in `/root/.ssh` if missing (printing the public key to stderr), then creates/updates `/workspace/.conda_env` from `/workspace/environment.yml`, then `exec "$@"`. A stamp file (`.conda_env/.environment.yml.stamp`) records the last successful create/update; a failed create removes the half-built env.
- `claudy`: **runs on the host**, not in the container. Wraps `podman run -it --rm`, mounts `$PWD` → `/workspace`, the config volume → `/claude-config` and a per-project SSH volume → `/root/.ssh`. The SSH volume is named `claude-ssh-<folder>-<8-char sha256 of $PWD>` (override: `CLAUDY_SSH`), so moving or renaming a project folder gives it a new key. `claudy pubkey` prints the public key; `CLAUDY_GIT_NAME`/`CLAUDY_GIT_EMAIL` override the image's git identity for one run. `claudy jupyter` publishes `127.0.0.1:8888`. `CLAUDY_NESTED=1` is the only way `/dev/fuse` is passed (plus `label=disable` and a per-project `/var/lib/containers` volume) and selects the `claudy-nested` image; on WSL it refuses unless `/mnt/<drive>` 9p mounts and `WSLInterop` binfmt entries are absent (override `CLAUDY_ALLOW_UNSAFE_NESTED=1`, don't use it).
- `environment.yml`: example/test project env. Per the README, real projects carry their own.

## Security model (do not weaken)

The full threat model and known limitations are in `SECURITY.md`; keep it in sync when changing mounts, capabilities, networking, nested mode or the image's supply chain.

- The container sees only `/workspace`, `/claude-config` and its own `/root/.ssh`. No host SSH keys, git credentials, Windows drives or extra mounts. The only mounts are `$PWD`, the config volume and the per-project SSH volume (one key per project, used as a GitLab *deploy key*; never mount host `~/.ssh` or an agent socket). Don't add other `-v`, `--privileged`, host networking, or port bindings on `0.0.0.0`.
- SSH keys are per project (one volume each) so containers can't cross-talk. Recommended use is a GitLab *deploy key* on a single repository, never a user-account key. The private key is readable by Claude; don't hide that in docs.
- **Nested mode is opt-in and off by default.** Never pass `/dev/fuse`, extra capabilities, `--privileged`, an unconfined seccomp profile or a host podman socket (a socket allows mounting any host path) in the default mode. In nested mode, pass only `/dev/fuse`. Don't remove the WSL check in `claudy`: the intended deployment is a dedicated WSL distro with `[automount] enabled=false` and `[interop] enabled=false` (README "Dedicated WSL distro"), because an escape from a WSL2 container reaches the Windows files and programs of the user.
- **Claude must not modify or help modify its own sandbox.** Never ask the user for their `sudo` password and never use `sudo` outside the container; if a task needs a rebuild, a package in the image, or a change to `claudy`/`Dockerfile`/`entrypoint.sh`, describe the change and ask the user to review and apply it from their own terminal outside `claudy`. Nested containers (inner `/var/lib/containers` volume) are fine for development work.
- Docs and scripts in this repo are public. Never add secrets, hostnames, usernames, project/dataset names or key material to any file here. Changes to `SECURITY.md`, `README.md` and `CLAUDE.md` weakening a stated protection need explicit user review, like code changes.
- Ports bind to `127.0.0.1` only.
- Conda channels: `conda-forge` and `bioconda` only. Never add Anaconda `defaults` (ToS/licensing).
- Never set or rely on `ANTHROPIC_API_KEY`; auth is the Claude Team (BioFAIR) subscription login stored in the volume.
- Network is unrestricted. That's a documented limitation, not something to "fix" silently.
- **Trust boundary:** when this repo itself is the mounted `/workspace`, Claude can edit `claudy`, which the user runs on the host (it's symlinked into `~/bin`). Treat changes to `claudy` and `Dockerfile` as needing explicit user review. The README's intended layout keeps this repo outside any project folder.

## Working here

- You are likely running inside this image as root (rootless Podman maps that to the host user). `podman` isn't available in the container, so you cannot build or run the image; validate with `bash -n` and by running scripts against a temp copy (e.g. `sed` the `/workspace` paths to a scratch dir).
- Changes to `entrypoint.sh` or `Dockerfile` take effect only after the user rebuilds: `podman build -t claudy .`.
- Git commits from the container use the env-var identity above; don't write a host `~/.gitconfig` or credentials into the image or volumes.
- Scripts use `set -euo pipefail` and bash arrays for argument lists; keep that style.
- `.conda_env/` and `*:Zone.Identifier` (Windows download metadata) are gitignored.

## Future work

Not yet done. Changes to `claudy` and `Dockerfile` need the user's review (see trust boundary above).

0. **Nested mode is unverified.** Build `--build-arg WITH_PODMAN=1`, run `CLAUDY_NESTED=1 claudy bash`, then `podman run --rm docker.io/library/hello-world` inside. If it fails with permission or mount errors, work out the *minimum* extra option (seccomp, a non-root inner user with subuid ranges, `/dev/net/tun`) and record it here; do not reach for `--privileged`. The WSL checks in `claudy` and the `wsl.conf` in the README also need a test on a real distro (`ls /mnt/c`, `cmd.exe`, nested refusal on the normal distro).
0. **Verify after first rebuild:** the new `Dockerfile` packages, git identity, ssh config, per-project key generation and `claudy pubkey` were written without being built or run (no `podman` in the container). Check `podman build` succeeds, `git commit` works with the default author, `claudy pubkey` prints a key, `ssh -T git@gitlab.com` authenticates with a deploy key, and a second project folder gets a different key.
1. **`claudy` hardening**
   - The `$PWD` guard refuses only `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`. Extend it to every Windows drive and every path under it (`/mnt/[a-z]`, `/mnt/[a-z]/*`) and to ancestors of `$HOME` (e.g. `/home`).
   - `-it` fails when stdin isn't a TTY (scripts, pipes). Add `-t` only when `[ -t 0 ]`.
   - Consider `--cap-drop=ALL --security-opt=no-new-privileges` on `podman run`; check that conda env creation and npm still work.
2. **Reproducible `Dockerfile`**: pin Miniforge to a release instead of `latest`, and pin `@anthropic-ai/claude-code` (e.g. via a build arg). The Miniforge URL is hard-coded to x86_64; derive the architecture with `uname -m` if ARM support is wanted.
3. **Jupyter dependency**: `claudy jupyter` needs `notebook` in the project's `environment.yml`; the base image has no Jupyter. At least document this in the README, or print a clear error when `jupyter` isn't on `PATH`.
4. **Non-root container user and per-project subuids (design idea, not started)**: today the container runs as in-container root, which rootless Podman maps to the host user, so a container escape lands as the user. Instead, a host-side setup script (run by the user, outside `claudy`, with `sudo` only for `/etc/subuid`) would allocate a distinct subuid range per project, create/prepare the project folder for it and print the matching launch options. `claudy` (or a separate launcher, e.g. `claudy-init` plus `claudy`) would then pass `--uidmap`/`--gidmap` (or `--subuidname`) for that project, plus a `USER` and home in the `Dockerfile`.
   - Benefit: an escape yields an unprivileged subuid that owns nothing else; projects cannot share a uid on the host.
   - Open problems: files created in the container are then owned by the subuid, so the user needs `podman unshare` or POSIX ACLs (`setfacl -R -m u:<user>:rwx` plus default ACLs on the project folder) to edit them from WSL; check that git on the host copes (`safe.directory`/dubious ownership) and that ACLs work on the WSL ext4 filesystem (not on `/mnt/<drive>`).
   - Simpler first step: `USER node` with `--userns=keep-id` (host uid = container uid, no ACLs needed). Still need to move `/root/.ssh`, `CLAUDE_CONFIG_DIR`, conda and npm paths to the user's home, and decide how packages get installed (`npm -g`, conda base and `apt` stop working for the unprivileged user).
   - Update `README.md` and `SECURITY.md` ("The container runs as in-container root") when done. Needs the user's review of `claudy`, `Dockerfile` and `entrypoint.sh`.
