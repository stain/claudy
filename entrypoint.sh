#!/bin/bash
set -euo pipefail

# claudy mounts the project at /projects/<folder>-<hash> (CLAUDY_PROJECT_DIR) and
# starts there. /workspace (empty or absent in the image) becomes a link to it, so
# the conda env, PATH and project files can keep using /workspace.
if [ -n "${CLAUDY_PROJECT_DIR:-}" ] && [ "$CLAUDY_PROJECT_DIR" != /workspace ] \
   && [ -d "$CLAUDY_PROJECT_DIR" ] && [ ! -L /workspace ]; then
    if [ -e /workspace ]; then rmdir /workspace; fi
    ln -s "$CLAUDY_PROJECT_DIR" /workspace
    # git checks the real path of the repository
    git config --system --add safe.directory "$CLAUDY_PROJECT_DIR"
fi

ENV_DIR=/workspace/.conda_env
YML=/workspace/environment.yml
# Touched after every successful create/update. conda-meta/history is not
# rewritten when an update changes nothing, so it can't be used for this.
STAMP="$ENV_DIR/.environment.yml.stamp"

# Per-project SSH key, kept in a volume mounted at /root/.ssh. Generated once; the
# public key is printed so it can be added as a GitLab deploy key.
SSH_DIR=/root/.ssh
if [ -d "$SSH_DIR" ] && [ ! -f "$SSH_DIR/id_ed25519" ]; then
    chmod 700 "$SSH_DIR"
    ssh-keygen -q -t ed25519 -N "" -C "claudy:${CLAUDY_PROJECT:-unknown}" -f "$SSH_DIR/id_ed25519"
    echo "Generated a new SSH key for this project. Public key (add as a GitLab deploy key):" >&2
    cat "$SSH_DIR/id_ed25519.pub" >&2
fi

# Nested podman: vfs works everywhere; with /dev/fuse (CLAUDY_NESTED=1) use overlay on
# fuse-overlayfs, which is faster and uses less disk. Rewritten on every start because
# the container is recreated each time.
if command -v podman >/dev/null 2>&1; then
    if [ -c /dev/fuse ] && command -v fuse-overlayfs >/dev/null 2>&1; then
        printf '[storage]\ndriver = "overlay"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n[storage.options.overlay]\nmount_program = "/usr/bin/fuse-overlayfs"\nignore_chown_errors = "true"\n' > /etc/containers/storage.conf
    else
        printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' > /etc/containers/storage.conf
    fi
fi

if [ -f "$YML" ]; then
    if [ ! -d "$ENV_DIR" ]; then
        echo "Creating conda env in $ENV_DIR ..."
        # Remove a half-built env so the next start retries instead of skipping it
        conda env create --prefix "$ENV_DIR" -f "$YML" || { rm -rf "$ENV_DIR"; exit 1; }
        touch "$STAMP"
    elif [ ! -f "$STAMP" ] || [ "$YML" -nt "$STAMP" ]; then
        echo "environment.yml changed, updating $ENV_DIR ..."
        conda env update --prefix "$ENV_DIR" -f "$YML" --prune
        touch "$STAMP"
    fi
fi

# Keep the env out of git without touching the project's .gitignore: '*' also
# ignores this file itself. Written after create/update, which want a clean dir.
if [ -d "$ENV_DIR/conda-meta" ]; then
    printf '*\n' > "$ENV_DIR/.gitignore"
    # Activate (CONDA_PREFIX, activate.d hooks); the exec'd command inherits it.
    # Activation scripts are not written for set -u.
    set +u
    eval "$(conda shell.bash hook)"
    conda activate "$ENV_DIR"
    set -u
fi

exec "$@"
