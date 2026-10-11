# Fully qualified so Podman doesn't prompt for / fail on short-name resolution
FROM docker.io/library/node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git procps openssh-client \
      jq unzip zip patch less file nano build-essential \
 && rm -rf /var/lib/apt/lists/*

# Miniforge: conda-forge only, no Anaconda "defaults" channel (ToS prompt / licensing)
ENV CONDA_DIR=/opt/conda
RUN curl -fsSL -o /tmp/miniforge.sh \
      https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
 && bash /tmp/miniforge.sh -b -p "$CONDA_DIR" \
 && rm /tmp/miniforge.sh

# Project env first on PATH for every process (claude, podman exec, VS Code terminals).
# A non-existent PATH entry is harmless until the env has been created.
ENV PATH=/workspace/.conda_env/bin:$CONDA_DIR/bin:$PATH

RUN npm install -g @anthropic-ai/claude-code

# Commit identity. Override per run with CLAUDE_BOX_GIT_NAME / CLAUDE_BOX_GIT_EMAIL (see claude-box)
ENV GIT_AUTHOR_NAME="Claude Sandbox" \
    GIT_AUTHOR_EMAIL="claude-sandbox@localhost" \
    GIT_COMMITTER_NAME="Claude Sandbox" \
    GIT_COMMITTER_EMAIL="claude-sandbox@localhost"
RUN git config --system --add safe.directory /workspace

# SSH: the per-project key lives in a volume mounted at /root/.ssh (see claude-box, entrypoint.sh).
# Only that key is offered; unknown hosts are recorded on first contact.
RUN mkdir -p /etc/ssh/ssh_config.d \
 && printf 'Host *\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' \
      > /etc/ssh/ssh_config.d/claude-box.conf

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Credentials and settings live in a named volume, not in the workspace
ENV SHELL=/bin/bash \
    CLAUDE_CONFIG_DIR=/claude-config

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
