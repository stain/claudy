# Fully qualified so Podman doesn't prompt for / fail on short-name resolution
FROM docker.io/library/node:22-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget git procps openssh-client \
      jq unzip zip patch less file nano build-essential \
 && rm -rf /var/lib/apt/lists/*

# Podman for nested containers. Works without /dev/fuse (vfs); with `CLAUDY_NESTED=1`
# the entrypoint switches storage to overlay on fuse-overlayfs. WITH_PODMAN=0 leaves it out.
# Settings follow the verified recipe in etc-claude-code/CLAUDE.md: root needs a subuid/subgid
# range, storage defaults to vfs (the entrypoint picks overlay when /dev/fuse exists), and nested containers use the host network and UTS namespace
# (builds use chroot isolation).
ARG WITH_PODMAN=1
RUN if [ "$WITH_PODMAN" = 1 ]; then \
      apt-get update && apt-get install -y --no-install-recommends \
        podman fuse-overlayfs slirp4netns uidmap \
      && rm -rf /var/lib/apt/lists/* \
      && echo 'root:1:65535' >> /etc/subuid \
      && echo 'root:1:65535' >> /etc/subgid \
      && mkdir -p /etc/containers/registries.conf.d \
      && printf 'unqualified-search-registries = ["docker.io"]\n' > /etc/containers/registries.conf.d/10-docker.conf \
      && printf '[containers]\nnetns = "host"\npidns = "host"\nutsns = "host"\n[engine]\ncgroup_manager = "cgroupfs"\nevents_logger = "file"\n' > /etc/containers/containers.conf \
      && printf '[storage]\ndriver = "vfs"\nrunroot = "/run/containers/storage"\ngraphroot = "/var/lib/containers/storage"\n' > /etc/containers/storage.conf ; \
    fi
ENV BUILDAH_ISOLATION=chroot

# Miniforge: conda-forge only, no Anaconda "defaults" channel (ToS prompt / licensing)
ENV CONDA_DIR=/opt/conda
RUN curl -fsSL -o /tmp/miniforge.sh \
      https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-Linux-x86_64.sh \
 && bash /tmp/miniforge.sh -b -p "$CONDA_DIR" \
 && rm /tmp/miniforge.sh \
 # Lock channel resolution: #!final keeps a user, $CONDARC or env-level .condarc (such as
 # /workspace/.conda_env/.condarc, which git ignores) from overriding these keys.
 # conda create/install refuse other channels; `conda env create/update -f` (conda 26.7)
 # does not check the allowlist, so environment.yml channels still need review.
 && printf '%s\n' \
      'allowlist_channels:  #!final' \
      '  - conda-forge' \
      '  - bioconda' \
      'channel_alias: https://conda.anaconda.org  #!final' \
      'custom_channels: {}  #!final' \
      'custom_multichannels: {}  #!final' \
      >> "$CONDA_DIR/.condarc"

# Project env first on PATH for every process (claude, podman exec, VS Code terminals).
# A non-existent PATH entry is harmless until the env has been created.
ENV PATH=/workspace/.conda_env/bin:$CONDA_DIR/bin:$PATH

# Interactive shells (claudy bash, podman exec -it): define the `conda` function and
# activate the project env if it exists. Not `conda init`, which would activate base.
# The entrypoint does the same for the started command. Login shells (VS Code builds its
# terminal and extension environment from one) inherit CONDA_PREFIX but get PATH reset by
# /etc/profile, so also activate when the env's bin is missing from PATH.
RUN printf '%s\n' \
      '. /opt/conda/etc/profile.d/conda.sh' \
      'if [ -d /workspace/.conda_env/conda-meta ]; then' \
      '    case "${CONDA_PREFIX:-}:$PATH:" in' \
      '        /workspace/.conda_env:*:/workspace/.conda_env/bin:*) ;;' \
      '        *) conda activate /workspace/.conda_env ;;' \
      '    esac' \
      'fi' >> /etc/bash.bashrc \
 # The entrypoint's activation already set CONDA_PROMPT_MODIFIER, but root's own
 # .bashrc resets PS1 afterwards, so re-add the "(env)" prefix there.
 && printf '%s\n' \
      'case "${CONDA_PROMPT_MODIFIER:-}" in "") ;; *) case "$PS1" in *"$CONDA_PROMPT_MODIFIER"*) ;; *) PS1="${CONDA_PROMPT_MODIFIER}${PS1}" ;; esac ;; esac' >> /root/.bashrc

RUN npm install -g @anthropic-ai/claude-code

# VS Code CLI for `claudy vscode` (VS Code in the browser, served from the container).
# Not on PATH: VS Code's own terminals provide a `code` command. WITH_VSCODE=0 leaves it out.
ARG WITH_VSCODE=1
RUN if [ "$WITH_VSCODE" = 1 ]; then \
      mkdir -p /opt/vscode \
      && curl -fsSL "https://code.visualstudio.com/sha/download?build=stable&os=cli-alpine-$(case "$(uname -m)" in aarch64) echo arm64 ;; *) echo x64 ;; esac)" \
         | tar -xz --no-same-owner -C /opt/vscode code ; \
    fi

# Commit identity. Override per run with CLAUDY_GIT_NAME / CLAUDY_GIT_EMAIL (see claudy)
ENV GIT_AUTHOR_NAME="Claude Sandbox" \
    GIT_AUTHOR_EMAIL="claude-sandbox@localhost" \
    GIT_COMMITTER_NAME="Claude Sandbox" \
    GIT_COMMITTER_EMAIL="claude-sandbox@localhost"
RUN git config --system --add safe.directory /workspace

# SSH: the per-project key lives in a volume mounted at /root/.ssh (see claudy, entrypoint.sh).
# Only that key is offered; unknown hosts are recorded on first contact.
RUN mkdir -p /etc/ssh/ssh_config.d \
 && printf 'Host *\n  IdentityFile ~/.ssh/id_ed25519\n  IdentitiesOnly yes\n  StrictHostKeyChecking accept-new\n' \
      > /etc/ssh/ssh_config.d/claudy.conf

COPY etc-claude-code/CLAUDE.md /etc/claude-code/CLAUDE.md
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
COPY vscode-serve.sh /usr/local/bin/vscode-serve
COPY git-identity-notice.sh /usr/local/bin/claudy-git-identity-notice
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/vscode-serve /usr/local/bin/claudy-git-identity-notice \
 # Interactive terminals (claudy bash, VS Code): warn about the placeholder commit identity.
 # Only with a TTY, so Claude's own non-interactive shells stay quiet.
 && printf '%s\n' \
      'case "$-" in *i*) [ -t 2 ] && claudy-git-identity-notice ;; esac' >> /etc/bash.bashrc

# Credentials and settings live in a named volume, not in the workspace
ENV SHELL=/bin/bash \
    CLAUDE_CONFIG_DIR=/claude-config

# claudy mounts the project at /projects/<folder>-<hash> only if this label says the
# entrypoint links /workspace to it; older images get the project at /workspace.
LABEL org.claudy.project-dir=1
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
# Absolute path: /workspace/.conda_env/bin is first on PATH, so a `claude` there would win
CMD ["/usr/local/bin/claude"]
