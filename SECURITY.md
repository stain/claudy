# Security analysis

A short threat model for the Claude Code sandbox in this repository: what it protects, what it does not, and the risks you accept by using it. It describes the design; parts of it (notably nested mode) have not been independently tested. Read it together with the *Security notes* in `README.md`.

## Goal and threat model

The goal is to limit the damage from **a mistake or misbehaviour of Claude Code or of code it runs**: a bad command, a malicious dependency, or a prompt injection hidden in a file, web page or dataset. The container makes it hard for such things to touch files outside one project folder, your personal SSH keys and git credentials, or other projects' keys.

It is not designed to stop a determined attacker with a kernel exploit, to keep data from leaving the machine, or to make untrusted software safe to run.

## What is protected

| Asset | Protection |
|---|---|
| Rest of the WSL/Linux filesystem, Windows drives | Not mounted; only `$PWD` is visible. `claudy` refuses `/`, `$HOME`, `/mnt/c` and `/mnt/c/Users/*`. |
| Your SSH keys, git credentials, agent | Never mounted or forwarded. |
| Other projects' SSH keys | One SSH key volume per project folder. |
| Host privileges | Rootless Podman: root in the container is your unprivileged user on the host. |
| Sandbox definition | Kept in a separate repository, so a project folder cannot overwrite it (see the first risk below). |

## Risks and limitations

### Data can leave the machine
Network access is unrestricted. Anything the container can read (the project, the SSH key, the Claude login) can be sent anywhere by Claude or by code it runs, for instance after a prompt injection. Project content is also sent to Anthropic as part of normal use. **Do not use this for data that must not leave the machine** (Trusted Research Environment data, patient data, data under a no-transfer agreement).

### The Claude login is exposed to the container
The subscription login lives in the `claude-config` volume, readable by everything in the container. The volume is shared by all projects, so it also holds other projects' transcripts. A compromised session could take the token and use your quota. Use `CLAUDY_CONFIG=claude-config-<project>` for separation (one login per project), and log out with `podman volume rm claude-config`.

### The project folder is writable and trusted by you later
Claude can change anything in `/workspace`: scripts, `Makefile`, notebooks, `.git/hooks`, `environment.yml`, IDE settings. If you later run or open those *outside* the container (a git hook, `make`, a Jupyter notebook on the host, VS Code tasks), the sandbox no longer applies. Review changes (`git diff`, including hooks) before running anything outside.

### SSH deploy keys reach beyond the container
The per-project private key is readable by Claude. With write access it can push to that repository, and a push can start GitLab CI, which runs with the project's CI secrets and runners, outside this sandbox. Use read-only deploy keys where possible, protect branches, and restrict who can change CI configuration. Never register this key on your user account.

### Self-modification of the sandbox
If this repository, or a folder containing it, is mounted as `/workspace`, Claude can edit `claudy`, `Dockerfile` or `entrypoint.sh`. These run on your host (`claudy`) or become the next image, with your rights. Keep the repository outside project folders and review `git diff` of those files before rebuilding. The same holds for the human steps: never give Claude the `sudo` password, and don't run Claude outside the container (see *Keep Claude away from the distro itself* in the README). Nothing technical enforces this; it relies on you.

### Shared kernel; container escapes
A container is not a virtual machine. A kernel or runtime vulnerability could let code in the container reach the host as your user. On **WSL2** all distros share one Linux kernel and VM, and by default your user can read and write the Windows drives (`/mnt/c`, as your Windows account) and start Windows programs through interop. For the strongest isolation use a dedicated WSL distro with `[automount] enabled = false` and `[interop] enabled = false`. This is *required* for nested mode and recommended otherwise.

### Nested mode (`CLAUDY_NESTED=1`)
Passing `/dev/fuse`, with SELinux labelling disabled, enlarges the kernel attack surface (FUSE, user namespaces, mounts). `claudy` refuses it on a WSL distro that still has Windows drives or interop, but this check is a guard against mistakes, not a security boundary (`CLAUDY_ALLOW_UNSAFE_NESTED=1` overrides it). Nested mode has not been verified end to end. Never mount a host Podman socket instead: it allows mounting any host path.

### Image and supply chain
The image is built from a floating `node:22-slim` tag, the latest Miniforge installer (downloaded and run without checksum verification), and unpinned `npm install -g @anthropic-ai/claude-code`. Conda packages come from `conda-forge` and `bioconda` without hash pinning. A compromise of any of these ends up inside the container, and inside your project through code that environment runs. Pin versions and checksums for stricter use (see *Future work* in `CLAUDE.md`).

### Weaker defaults
The container uses Podman's default capability set and default seccomp profile; there is no `--cap-drop=ALL`, `no-new-privileges`, read-only root filesystem or resource limits (CPU, memory, processes). A runaway process can exhaust the host's resources. The container runs as in-container root.

### Jupyter
`claudy jupyter` binds to `127.0.0.1` on the host and uses a token, but on WSL2 `localhost` is forwarded to Windows, so any local Windows process or browser tab can reach it. Anyone with the token can run code in the container.

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
| Unintended access to the Windows drives (with the dedicated distro) | Kernel or runtime escapes, a shared WSL2 kernel |
| | Supply-chain compromise of the image or conda packages |

## Reporting

Report suspected vulnerabilities in this repository privately through GitHub security advisories on https://github.com/stain/claudy, rather than a public issue.
