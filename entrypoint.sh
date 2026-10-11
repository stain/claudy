#!/bin/bash
set -euo pipefail

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

exec "$@"
