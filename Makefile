# Build the claudy image with Podman. Runs on the host, like `claudy`, not in the container.
#
#   make                    build localhost/claudy:latest
#   make rebuild            pull a fresh base image and rebuild without cache (updates Claude Code)
#   make BUILD_ARGS='--build-arg WITH_VSCODE=0'
#
# The dedicated WSL distro (README, "Dedicated WSL distro") pins `make` away; run
# `podman build -t claudy .` there instead.

PODMAN ?= podman
IMAGE ?= claudy
BUILD_ARGS ?=

# The repository, so `make -C ~/claudy` and `make -f ~/claudy/Makefile` build the same context
REPO := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

.PHONY: build rebuild check check-podman check-host check-wsl

build: check
	$(PODMAN) build -t $(IMAGE) $(BUILD_ARGS) "$(REPO)"

rebuild: check
	$(PODMAN) build --pull --no-cache -t $(IMAGE) $(BUILD_ARGS) "$(REPO)"

check: check-podman check-host check-wsl

check-podman:
	@command -v $(PODMAN) >/dev/null 2>&1 || { \
	  echo "make: '$(PODMAN)' not found. Install Podman first (README, Prerequisites)," >&2; \
	  echo "      e.g. on Ubuntu: sudo apt update && sudo apt install -y podman" >&2; \
	  exit 1; }

# The image is built by the user on the host, never from inside a claudy container
check-host:
	@if [ -n "$${CLAUDY_PROJECT_DIR:-}" ] || [ -e /run/.containerenv ]; then \
	  echo "make: this looks like a container. Build the claudy image on the host, outside claudy." >&2; \
	  exit 1; fi

# Warn only: an everyday WSL distro is a supported setup (README, "Where to run it")
check-wsl:
	@if grep -qi microsoft /proc/version 2>/dev/null; then \
	  warn=0; \
	  if grep -qE ' /mnt/[a-z] (9p|drvfs) ' /proc/mounts; then \
	    echo "make: warning: Windows drives are mounted in this WSL distro (/mnt/<drive>)." >&2; warn=1; fi; \
	  if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then \
	    echo "make: warning: Windows interop is enabled in this WSL distro (WSLInterop handler registered)." >&2; warn=1; fi; \
	  case "$(REPO)" in /mnt/*) \
	    echo "make: warning: this repository is on a Windows drive ($(REPO)); keep it on the Linux filesystem (~/claudy)." >&2; warn=1;; esac; \
	  if [ "$$warn" = 1 ]; then \
	    echo "      A container escape here would reach your Windows files and programs, and CLAUDY_NESTED=1 is refused." >&2; \
	    echo "      Recommended: a dedicated distro from new-claudy-distro.ps1 (README, \"Where to run it\" and \"Dedicated WSL distro\")." >&2; \
	  fi; \
	fi
