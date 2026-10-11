#!/bin/bash
set -euo pipefail

ENV_DIR=/workspace/.conda_env
YML=/workspace/environment.yml
# Touched after every successful create/update. conda-meta/history is not
# rewritten when an update changes nothing, so it can't be used for this.
STAMP="$ENV_DIR/.environment.yml.stamp"

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
