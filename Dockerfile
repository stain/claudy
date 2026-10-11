FROM node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git procps \
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

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Credentials and settings live in a named volume, not in the workspace
ENV SHELL=/bin/bash \
    CLAUDE_CONFIG_DIR=/claude-config

WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
