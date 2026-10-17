# Security analysis

A short threat model for the Claude Code sandbox in this repository: what it protects, what it does not, and the risks you accept by using it. It describes the design; parts of it (notably nested mode) have not been independently tested. Read it together with the *Security notes* in `README.md`.

## Goal and threat model

The goal is to limit the damage from **a mistake or misbehaviour of Claude Code or of code it runs**: a bad command, a malicious dependency, or a prompt injection hidden in a file, web page or dataset. The container makes it hard for such things to touch files outside one project folder, your personal SSH keys and git credentials, or other projects' keys.

It is not designed to stop a determined attacker with a kernel exploit, to keep data from leaving the machine, or to make untrusted software safe to run.

## What is protected

| Asset | Protection |
|---|---|
| Rest of the WSL/Linux filesystem, Windows drives | Not mounted; only `$PWD` is visible. `claudy` refuses `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`. Root in the WSL distro can still mount the Windows drives (see *WSL2 is not a virtual machine boundary*). |
| Your SSH keys, git credentials, agent | Never mounted or forwarded. |
| Other projects' SSH keys | One SSH key volume per project folder. |
| Host privileges | Rootless Podman: root in the container is your unprivileged user on the host. |
| Sandbox definition (`claudy`, `Dockerfile`, image) | Kept in a separate repository, so a project folder cannot overwrite it (see *Self-modification* below). Claude may change the *running* container, but those changes are discarded on exit. |

## Risks and limitations

### Data can leave the machine
Network access is unrestricted. Anything the container can read (the project, the SSH key, the Claude login) can be sent anywhere by Claude or by code it runs, for instance after a prompt injection. Project content is also sent to Anthropic as part of normal use. **Do not use this for data that must not leave the machine** (Trusted Research Environment data, patient data, data under a no-transfer agreement).

### The Claude login is exposed to the container
The subscription login lives in the `claude-config` volume, readable by everything in the container. The volume is shared by all projects, so it also holds other projects' transcripts. Because every project is mounted at the same path (`/workspace`), they also share a single Claude memory folder, so memories from one project are loaded into sessions in another. A compromised session could take the token and use your quota.

The volume is also **writable and persistent**, so it is a channel between sessions and projects: settings and hooks (`settings.json`, which can run commands in every later session), and memory files are read by later sessions in other projects. A prompt injection in one project can plant instructions or hooks that act in another. Use `CLAUDY_CONFIG=claude-config-<project>` for separation (one login per project), and log out with `podman volume rm claude-config`.

### The project folder is writable and trusted by you later
Claude can change anything in `/workspace`: scripts, `Makefile`, notebooks, `.git/hooks`, `environment.yml`, IDE settings. If you later run or open those *outside* the container (a git hook, `make`, a Jupyter notebook on the host, VS Code tasks), the sandbox no longer applies. Review changes (`git diff`, including hooks) before running anything outside.

### The project conda env is persistent and not reviewed
The project's conda environment lives in the project folder (`.conda_env/`), so it survives between runs, and it is only updated when `environment.yml` changes, never rebuilt from scratch. Claude and any code it runs can change it, and it ignores itself in git (its own `.gitignore` with `*`), so `git diff` never shows those changes. A compromised session can therefore leave something behind that runs in every later session of that project, although each session starts a new container:

* activation hooks (`.conda_env/etc/conda/activate.d/*.sh`), which the entrypoint and interactive shells source on every start, before Claude runs;
* replaced or added programs in `.conda_env/bin`, which is first on `PATH` and so shadows `git`, `ssh`, `python` and the rest;
* an env-level `.conda_env/.condarc`.

Outside the container it is worse: if you activate the environment on the host, run anything from `.conda_env/bin`, or let an IDE use it as a Python interpreter (VS Code's Python extension discovers environments in the workspace and runs their `python`), that code runs as you, outside the sandbox.

* Treat `.conda_env` as untrusted. Never activate or run it outside `claudy`; in a host IDE, choose another interpreter.
* Delete it (`rm -rf .conda_env`) after a session you don't trust, before trusting a project again, and when copying a project elsewhere. The next start rebuilds it from `environment.yml`.
* Review `environment.yml` in `git diff` like code: its channels, and its `pip:` entries (any package index, `git+https` URLs, local paths whose build scripts run at install time).

What the image does about it: it starts Claude by absolute path (`/usr/local/bin/claude`), so a `claude` in `.conda_env/bin` is not run instead. That does not stop an activation hook, which runs earlier as root in the container. The image's `/opt/conda/.condarc` allows only the `conda-forge` and `bioconda` channels and locks the channel settings (`allowlist_channels`, `channel_alias`, `custom_channels`, `custom_multichannels`) with `#!final`, so a `.condarc` in the environment or in `$CONDARC` cannot redirect or extend them. `conda install` and `conda create` refuse other channels, but `conda env create`/`update -f`, which the entrypoint uses, does not check the allowlist (as of conda 26.7), so a channel in `environment.yml` is still used. `pip:` entries are not restricted at all. A running session can also edit `/opt/conda/.condarc` itself; that change is lost when the container stops.

### SSH deploy keys reach beyond the container
The per-project private key is readable by Claude. With write access it can push to that repository, and a push can start GitLab CI, which runs with the project's CI secrets and runners, outside this sandbox. Use read-only deploy keys where possible, protect branches, and restrict who can change CI configuration. Never register this key on your user account.

### Claude changes the running container
Claude is allowed to change the container it runs in (install packages with `apt`, edit `/etc`, add tools) to get its work done. This does not touch the image or the host: the container is recreated on every `claudy` start, so the changes are lost. What does persist is anything written to `/workspace`, `/claude-config`, `/root/.ssh` and, in nested mode, the inner container volume.

Agents are instructed to put environment changes a project needs again into that project, in its own convention (conda `environment.yml`, `pyproject.toml`, a `Dockerfile`, the README), and not into shared storage such as `/claude-config`. That keeps them per project and visible in `git diff`, where they fall under *The project folder is writable* above: review them before running them outside the container, and before copying anything into the sandbox `Dockerfile`. The instruction is guidance; nothing stops a compromised session from writing to the shared config volume.

### Self-modification of the sandbox
If this repository, or a folder containing it, is mounted as `/workspace`, Claude can edit `claudy`, `Dockerfile` or `entrypoint.sh`. These run on your host (`claudy`) or become the next image, with your rights. Keep the repository outside project folders and review `git diff` of those files before rebuilding. The same holds for the human steps: never give Claude the `sudo` password, and don't run Claude outside the container (see *Keep Claude away from the distro itself* in the README). Nothing technical enforces this; it relies on you.

### Shared kernel; container escapes
A container is not a virtual machine. A kernel or runtime vulnerability could let code in the container reach the host as your user. On **WSL2** all distros share one Linux kernel and VM, and by default your user can read and write the Windows drives (`/mnt/c`, as your Windows account) and start Windows programs through interop. For the strongest isolation use a dedicated WSL distro with `[automount] enabled = false` and `[interop] enabled = false`. This is *required* for nested mode and recommended otherwise. Trim that distro to what `claudy` needs (README, *Trim the distro*): every other package there, especially services and agents such as `wsl-pro-service`, `landscape-client` or `snapd`, runs as your user or as root next to the sandbox and is reachable after an escape.

### WSL2 is not a virtual machine boundary to Windows
A WSL2 distro is not isolated from Windows the way a separate virtual machine is. WSL is built to share files and programs with the Windows account that starts it, and the dedicated distro's `wsl.conf` settings only switch off the *automatic* parts at startup. They are not a boundary against root *inside* the distro. Tested on Ubuntu 26.04 with automount and interop disabled:
* `mount -t drvfs C: /mnt/c`, run as root in the distro, **mounts the Windows drive again** (confirmed), readable and writable with the rights of the Windows account that started WSL.
* The `WSLInterop` handler stays registered. Starting a Windows `.exe` timed out (`UtilAcceptVsock: accept4 failed 110`) instead of running, but don't rely on that.

From inside a `claudy` container (tested in the default mode) the drives can't be mounted this way: container root is your Linux user in a user namespace, without `CAP_SYS_ADMIN`, so mounting `9p` (what drvfs uses) or `binfmt_misc` is refused, and the image has no `/init` or `mount.drvfs`. The kernel doesn't allow `9p` mounts from a user namespace even with that capability, so nested containers can't either. An escape to root in the distro (a kernel or runtime exploit, or the `sudo` password) would get around this.

Windows programs are a different case: `binfmt_misc` handlers are registered for the whole kernel, and the distro's `WSLInterop` handler **also applies inside the container** (tested): starting an `.exe` there runs the distro's WSL `/init` inside the container, although the image has no `/init`. In the test it stopped early (`UtilGetPpid: Failed to parse: /proc/1/stat`, because the container's PID 1 is `bash`) before contacting Windows. That is incidental, not a protection: with interop enabled in the distro, assume that code in a `claudy` container can start Windows programs as your Windows user. This is one more reason to use the dedicated distro with interop disabled.

WSL talks to Windows over vsock (`AF_VSOCK`), which network namespaces don't isolate: processes in a `claudy` container can open vsock sockets (tested), so whatever the Windows side of WSL still listens on is reachable from inside the container without root. This has not been probed further.

So the dedicated distro protects your Windows files only as long as nothing from the container gets root in the distro. Rootless Podman means an escape lands as your Linux user, not root. Never give Claude the `sudo` password and don't enable passwordless `sudo`. A kernel exploit that gives root in the WSL2 VM reaches your Windows files regardless. For a stronger boundary, run the distro under a separate, unprivileged Windows account (drives mounted from it then carry only that account's rights), or use a full virtual machine instead of WSL2.

### Nested containers
The image includes Podman, which works in the default mode too, with the `vfs` storage driver. It needs no extra device or capability: the default container already lets any process create user namespaces and mount filesystems inside them (Podman's default seccomp profile allows it), so installing Podman does not open a new kernel interface. It does make heavy use of it routine. User namespaces are a frequent source of Linux kernel privilege-escalation bugs, so the shared-kernel risk above applies to the default mode as well, and the dedicated WSL distro is recommended for any use of Podman inside, not only nested mode. Blocking user namespaces (a custom seccomp profile, or `user.max_user_namespaces=0` in the distro) would remove that surface but also break nested Podman.

Inner containers share the outer container's network (`--network=host` inside means the container's own network namespace, not the host's) and see only what the outer container sees. Images are pulled from Docker Hub without signature checks, and `vfs` copies every layer in full, so builds can fill the disk (see *Weaker defaults*). Without nested mode, inner images live in the container's writable layer and are lost on exit.

### Nested mode (`CLAUDY_NESTED=1`)
Nested mode adds `/dev/fuse` (the entrypoint then switches Podman to `overlay` on `fuse-overlayfs`), SELinux labelling disabled, and a persistent per-project volume for inner images. FUSE and disabled labelling enlarge the kernel attack surface further. `claudy` refuses it on a WSL distro that still has Windows drives or interop, but this check is a guard against mistakes, not a security boundary (`CLAUDY_ALLOW_UNSAFE_NESTED=1` overrides it). Nested mode has not been verified end to end. Never mount a host Podman socket instead: it allows mounting any host path.

### Image and supply chain
The image is built from a floating `node:22-slim` tag, the latest Miniforge installer (downloaded and run without checksum verification), and unpinned `npm install -g @anthropic-ai/claude-code`. Conda packages come from `conda-forge` and `bioconda` without hash pinning (the channel allowlist does not cover `environment.yml` or `pip:`, see *The project conda env* above), and nested containers pull images from Docker Hub without verification. Packages Claude installs at runtime (`apt`, `pip`, `npm`) are further unpinned inputs. A compromise of any of these ends up inside the container, and inside your project through code that environment runs. Pin versions and checksums for stricter use (see *Future work* in `CLAUDE.md`).

### Weaker defaults
The container uses Podman's default capability set and default seccomp profile; there is no `--cap-drop=ALL`, `no-new-privileges`, read-only root filesystem or resource limits (CPU, memory, processes). A runaway process, or a nested build on `vfs` storage, can exhaust the host's CPU, memory or disk. The container runs as in-container root.

### Published ports (Jupyter, `--ports`)
No ports are published by default. `claudy jupyter` (8888) and `claudy --ports ...` bind the listed ports to `127.0.0.1` on the host, but on WSL2 `localhost` is forwarded to Windows, so any local Windows process or browser tab can reach them. Jupyter uses a token, and anyone with it can run code in the container. A dev server on a `--ports` port usually has no authentication at all, so anything local, including a malicious web page in your browser making requests to `localhost`, can talk to it. Publish ports only for the session that needs them.

### Human factors
The sandbox makes broad permission modes (such as auto-approving tool use) less risky, not safe. Don't put secrets you wouldn't give Claude into a project (`.env`, tokens, keys), and don't paste the `sudo` password into any session.

## This document is public

`SECURITY.md` is published on GitHub, so assume an attacker has read it, and that Claude can read it too whenever this repository is mounted (as when working on the sandbox itself). That is acceptable because none of the protections depend on secrecy: the weaknesses listed here are generic to containers, and a model or attacker can find them without this file. Still:

* **Keep it free of secrets and site-specific detail**: no hostnames, usernames, project or dataset names, tokens, key fingerprints or internal GitLab URLs, in this file or anywhere else in the repository. Put local notes outside the repository.
* **Integrity matters more than confidentiality.** If Claude can edit this repository, it could weaken `SECURITY.md`, `README.md` or `CLAUDE.md` to hide a change, or plant instructions there. Review `git diff` of all documentation and scripts, not just the code, before you trust or rebuild from them, and read the published version on GitHub for the baseline.
* **Don't treat the document as a control.** It cannot stop a compromised session; the container boundary and your review do.

## Summary

| Good protection against | Little or no protection against |
|---|---|
| Accidental deletion or edits outside the project | Exfiltration over the network |
| Access to your personal SSH keys and git credentials | Theft of the Claude login and project deploy key |
| Cross-project key reuse | Tampering that you later execute outside the container |
| Lasting changes to the image from inside the container | Cross-project influence through the shared `claude-config` volume (hooks, memory) |
| Unintended access to the Windows drives (with the dedicated distro) | Kernel or runtime escapes, a shared WSL2 kernel; root in the distro can mount the Windows drives |
| | Supply-chain compromise of the image or conda packages |
| | Tampering in `.conda_env`, which persists between sessions and is not in `git diff` |

## Reporting

Report suspected vulnerabilities in this repository privately through GitHub security advisories on https://github.com/stain/claudy, rather than a public issue.
