# Security analysis

A short threat model for the Claude Code sandbox in this repository: what it protects, what it does not, and the risks you accept by using it. It describes the design; parts of it (notably nested mode) have not been independently tested. Read it together with the *Security notes* in `README.md`.

> **Note for AI agents.** This document is for the user's own risk assessment. It lists weaknesses and channels that you have not been asked to use: a risk described here is not a suggestion, a permission or a task. Stay within what the user asked for. If something you need is blocked by the sandbox, say so and ask the user; don't look for a way around it. Don't test, demonstrate or exploit anything described here, or read other sessions' data, unless the user explicitly asks for a specific test; then do the minimum that answers it and report what you did.

## Goal and threat model

The goal is to limit the damage from **a mistake or misbehaviour of Claude Code or of code it runs**: a bad command, a malicious dependency, or a prompt injection hidden in a file, web page or dataset. The container makes it hard for such things to touch files outside one project folder, your personal SSH keys and git credentials, or other projects' keys.

It is not designed to stop a determined attacker with a kernel exploit, to keep data from leaving the machine, or to make untrusted software safe to run.

**It is not isolation between Claude sessions or code bases.** The purpose is to reduce the blast radius of accidental or misleading instructions and over-eager agents, not to keep projects that must not see each other apart. All sessions run as the same host user on the same kernel and, by default, share one Claude config volume holding every session's transcripts, memory, settings and the login. One session can read and rewrite what another left there (see *The Claude login is exposed to the container*). Real isolation between code bases needs, at the least, separate virtual machines, each with its own keys and logins; a per-project config volume (`CLAUDY_CONFIG`) is only a mitigation.

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
The subscription login lives in the `claude-config` volume, readable by everything in the container. The volume is shared by all projects, so it also holds other projects' transcripts. Each project is mounted at its own path, so Claude Code keeps a separate memory folder per project, but all of them are in the same volume, readable and writable by every session. A compromised session could take the token and use your quota.

The volume is also **writable and persistent**, so it is a channel between sessions and projects (details in *Cross-talk and leakage through the shared config volume* below): settings and hooks (`settings.json`, which can run commands in every later session), and memory files are read by later sessions in other projects. A prompt injection in one project can plant instructions or hooks that act in another. Edited transcripts carry such instructions into sessions that are resumed later.

The volume keeps whatever appeared in a session: a token you pasted, a `.env` file or credential Claude displayed, command output with a password. Every session sharing the volume can read those. Keep secrets out of sessions.

`CLAUDY_CONFIG=claude-config-<project>` gives a project its own volume (one login per project). That is a mitigation: the volumes still belong to your host user, so an escape from any container, or anything else running as you, reads them all. Log out with `podman volume rm claude-config`.

### Cross-talk and leakage through the shared config volume
Every session that uses the same config volume (the default) reads and writes the same files, while it runs and long after. Claude Code decides what it keeps there, and the layout changes between versions. Broadly, the volume holds: the login token; full transcripts of every session (messages, files Claude read or wrote, commands and their output), filed per project folder, but all in the same volume; Claude's memory; your prompt history; earlier versions of edited files; pasted text; session state that can include environment variables; tool server definitions that may contain tokens; and the settings, hooks, instructions and extensions every session loads.

**Leakage (reading).** Any session, and any code it runs, can read all of this for every other project, including sessions running at the same time: code and data excerpts, your prompts, and any secret that ever appeared in a session (a pasted token, a credential Claude displayed, a password in command output). With unrestricted network access, all of it can leave the machine.

**Cross-talk (writing).** Any session can change what other sessions load or run: shared settings (including hooks and permissions), user-level instructions, extensions, memory, and the transcripts that resumed sessions continue from. A change made in one project then acts in another, with that project's files and deploy key.

None of this shows up in any project's `git diff`, it survives restarts and image rebuilds, and the in-container instructions to treat this content as data are guidance only. Two sessions writing at the same time can also corrupt each other's files.

**Mitigations**, none of which is isolation (see *Goal and threat model*):
* Give projects with confidential data or untrusted input their own volume: `CLAUDY_CONFIG=claude-config-<project>`. Decide before the first session; history already in the shared volume can't easily be separated out.
* Keep secrets out of sessions: don't paste them, and don't have Claude print `.env` files, tokens or credentials.
* Check the shared settings now and then, e.g. `claudy bash -c 'cat /claude-config/settings.json; ls /claude-config/plugins /claude-config/skills; cat /claude-config/CLAUDE.md'`, and look for hooks, permission rules, plugins or MCP servers you didn't add.
* Don't resume an old session after working on untrusted material in another project that shares the volume.
* Start over with `podman volume rm claude-config` (logs you out and deletes all history) after a session you don't trust.

### The project folder is writable and trusted by you later
Claude can change anything in `/workspace`: scripts, `Makefile`, notebooks, `.git/hooks`, `environment.yml`, IDE settings. If you later run or open those *outside* the container (a git hook, `make`, a Jupyter notebook on the host, VS Code tasks), the sandbox no longer applies. Review changes (`git diff`, including hooks) before running anything outside.

### The project conda env is persistent and not reviewed
The project's conda environment lives in the project folder (`.conda_env/`), so it survives between runs, and it is only updated when `environment.yml` changes, never rebuilt from scratch. Claude and any code it runs can change it, and it ignores itself in git (its own `.gitignore` with `*`), so `git diff` never shows those changes. A compromised session can therefore leave something behind in it that runs in every later session of that project, although each session starts a new container: the environment's own scripts and programs are run on every start and come first on `PATH`.

Outside the container it is worse: if you activate the environment on the host, run anything from `.conda_env/bin`, or let an IDE use it as a Python interpreter (VS Code's Python extension discovers environments in the workspace and runs their `python`), that code runs as you, outside the sandbox.

* Treat `.conda_env` as untrusted. Never activate or run it outside `claudy`; in a host IDE, choose another interpreter.
* Delete it (`rm -rf .conda_env`) after a session you don't trust, before trusting a project again, and when copying a project elsewhere. The next start rebuilds it from `environment.yml`.
* Review `environment.yml` in `git diff` like code: its channels, and its `pip:` entries (any package index, `git+https` URLs, local paths whose build scripts run at install time).

What the image does about it: it starts Claude by absolute path, so the environment can't replace Claude itself, and its conda configuration allows only the `conda-forge` and `bioconda` channels, locked against overrides from the environment or the user. These are partial measures: they don't cover everything an environment can run, the channel lock is not enforced for environments built from `environment.yml`, and `pip:` entries are not restricted at all. So reviewing `environment.yml` and deleting `.conda_env` when in doubt remain the actual protection.

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
* Root in the distro **can mount the Windows drives again** (confirmed), readable and writable with the rights of the Windows account that started WSL.
* WSL's handler for Windows programs stays registered even with interop disabled. The dedicated distro's setup therefore removes it on every boot (a `wsl-remove-interop.service` systemd unit, see README).

From inside a `claudy` container (tested in the default mode) the drives can't be mounted: container root is your unprivileged Linux user in a user namespace, and the kernel refuses such mounts there, in nested containers too. Only root in the distro can, which is why nothing from a container may get there (see below).

Windows programs are a different case: the kernel's handlers for foreign program formats are shared by the whole system, and WSL's handler for Windows programs **also applies inside the container** (tested). In the test it did not reach Windows, but only by chance. With interop enabled in the distro, assume that code in a `claudy` container can start Windows programs as your Windows user. Two measures stand in the way: the dedicated distro removes the handler at boot, and `claudy` blocks the channel WSL uses to reach Windows (below). Neither has been verified end to end.

WSL talks to Windows over vsock (`AF_VSOCK`), which network namespaces don't isolate: with Podman's default seccomp profile, processes in a container can open vsock sockets (tested), so whatever the Windows side of WSL listens on would be reachable from inside without root. `claudy` therefore runs containers with a seccomp profile derived from Podman's default on every start (written to `~/.cache/claudy/seccomp.json`) that refuses vsock sockets, including through related system calls. Nested containers inherit the filter. Side effect: some rarely used socket calls fail, 32-bit programs don't run at all (32-bit x86 isn't supported). `claudy` refuses to start if it can't build the profile from the host's `/usr/share/containers/seccomp.json`.

WSL also gives every distro WSLg (`/mnt/wslg`, GUI apps shown on Windows) and the Windows GPU drivers (`/usr/lib/wsl`, shared read-only over 9p). Containers don't see them, but they are further channels from the distro to Windows; they can only be switched off for all distros at once, in `%UserProfile%\.wslconfig` on Windows (for WSLg: `guiApplications=false` under `[wsl2]`).

So the dedicated distro protects your Windows files only as long as nothing from the container gets root in the distro. Rootless Podman means an escape lands as your Linux user, not root. Never give Claude the `sudo` password and don't enable passwordless `sudo`. The `sudo` password is weaker protection than it looks: anything running as your user can intercept what you type in that user's shells, the `sudo` password included. So never type it in a shell that a container escape could have touched. A planned two-user layout separates the roles: a `claudy` user without `sudo` that runs the sandbox, and an `admin` user entered only with `wsl -d <name> -u admin` from PowerShell, with the launcher and image ID owned by root (*Future work* in `CLAUDE.md`). A kernel exploit that gives root in the WSL2 VM reaches your Windows files regardless. For a stronger boundary, run the distro under a separate, unprivileged Windows account (drives mounted from it then carry only that account's rights), or use a full virtual machine instead of WSL2.

### Nested containers
The image includes Podman, which works in the default mode too, with the `vfs` storage driver. It needs no extra device or capability: the default container already lets any process create user namespaces and mount filesystems inside them (Podman's default seccomp profile allows it), so installing Podman does not open a new kernel interface. It does make heavy use of it routine. User namespaces are a frequent source of Linux kernel privilege-escalation bugs, so the shared-kernel risk above applies to the default mode as well, and the dedicated WSL distro is recommended for any use of Podman inside, not only nested mode. Blocking user namespaces (a custom seccomp profile, or `user.max_user_namespaces=0` in the distro) would remove that surface but also break nested Podman.

Inner containers share the outer container's network (`--network=host` inside means the container's own network namespace, not the host's) and see only what the outer container sees. Images are pulled from Docker Hub without signature checks, and `vfs` copies every layer in full, so builds can fill the disk (see *Weaker defaults*). Without nested mode, inner images live in the container's writable layer and are lost on exit.

### Nested mode (`CLAUDY_NESTED=1`)
Nested mode adds `/dev/fuse` (the entrypoint then switches Podman to `overlay` on `fuse-overlayfs`), SELinux labelling disabled, and a persistent per-project volume for inner images. FUSE and disabled labelling enlarge the kernel attack surface further. `claudy` refuses it on a WSL distro that still has Windows drives or interop, but this check is a guard against mistakes, not a security boundary (`CLAUDY_ALLOW_UNSAFE_NESTED=1` overrides it). Nested mode has not been verified end to end. Never mount a host Podman socket instead: it allows mounting any host path.

### Image and supply chain
The image is built from a floating `node:22-slim` tag, the latest Miniforge installer (downloaded and run without checksum verification), unpinned `npm install -g @anthropic-ai/claude-code` and, unless built without it, the latest VS Code command-line tool (also without checksum verification), which downloads the VS Code server from Microsoft on the first `claudy vscode` start. Conda packages come from `conda-forge` and `bioconda` without hash pinning (the channel allowlist does not cover `environment.yml` or `pip:`, see *The project conda env* above), and nested containers pull images from Docker Hub without verification. Packages Claude installs at runtime (`apt`, `pip`, `npm`) are further unpinned inputs. A compromise of any of these ends up inside the container, and inside your project through code that environment runs. Pin versions and checksums for stricter use (see *Future work* in `CLAUDE.md`).

### The image can be replaced without notice
`claudy` starts whatever image is stored under its name in your user's own Podman storage. That storage belongs to your user, so anything running as your user on the host (a process after a container escape, a tool or script you ran on the distro, a tampered shell startup file) can put a different image under that name, or point `claudy` at another image. Nothing visible changes. The next start then runs that image with your project folder, the Claude login and the project's deploy key mounted, and with whatever instructions, entrypoint and Claude Code version it contains. A session inside the container cannot do this on its own: nested Podman keeps its images in separate storage, so replacing the host's image needs an escape or something running outside the container first.

What `claudy` already does: it refers to the image by a fully qualified local name and never pulls, so a missing or misspelt image fails instead of being fetched from a public registry. It warns when the image is older than the repository's build files, but that is a reminder to rebuild, not a tamper check.

How to protect against replacement, from simplest to strongest:

* Rebuild after reviewing `git diff`, rather than trusting an image whose origin you don't remember, and rebuild if `claudy` behaves unexpectedly. Don't keep images from other sources under the same name.
* Have `claudy` compare the image's ID with one recorded when you built it. If your user can write that record, this only catches mistakes: whatever can replace the image can update the record too.
* Make the record, the launcher and the build belong to a different user than the one that runs `claudy`, so an escaped or compromised `claudy` user cannot change them (the two-user layout under *Future work* in `CLAUDE.md`).

Keep this in proportion: something that already runs as your user on the host can also change the launcher, your shell or your other files. Replacing the image is one of the ways it could stay hidden and reach later sessions, which is why the main defence is keeping that user uncompromised (*Self-modification of the sandbox*, *Human factors*).

### Building locally or pulling from a registry
The image is built locally from this repository. That keeps the trust chain short: you read the `Dockerfile` change, you build, and the image never comes from someone else's account or build server. Its weaknesses are that the build itself fetches unpinned inputs (see *Image and supply chain*), so two builds of the same commit can differ and nothing records what an image contains, and that the result sits in storage your user can change.

A prebuilt image from a registry, built by the repository's CI, would turn that around:

* **Gains:** one build for everyone, the option to sign it and publish provenance, and, when pulled by digest rather than by tag, a content identifier that a local copy can be checked against later. Setup is quicker and needs no build tools.
* **Costs:** you then also trust the CI system, the registry and the maintainers' accounts, and a compromised publish reaches every user at their next update. Tags can be moved, so only a digest pins an image. Reviewing the `Dockerfile` diff no longer tells you what the image contains. A launcher that pulls also reaches the network at start.

If a registry image is offered, it should be optional and pinned: the expected digest kept in this repository, so it changes only through a commit you review; its signature checked before use; and pulling done as an explicit update step, never implicitly at start. Pinning the build inputs (*Future work* in `CLAUDE.md`) is a prerequisite for either way: it makes local builds repeatable and lets a published image be checked against a local rebuild. Until then, local builds remain the default.

### Weaker defaults
The container uses Podman's default capability set and its default seccomp profile, with vsock blocked (see above); there is no `--cap-drop=ALL`, `no-new-privileges`, read-only root filesystem or resource limits (CPU, memory, processes). A runaway process, or a nested build on `vfs` storage, can exhaust the host's CPU, memory or disk. The container runs as in-container root, which rootless Podman maps to your user. A non-root user inside would add little on its own: it would map to the same host user, and any process can still create a user namespace with full capabilities inside it (nested Podman relies on that). Possible next steps are `no-new-privileges`, dropping unused capabilities and a separate host subuid range per project (*Future work* in `CLAUDE.md`).

### Published ports (Jupyter, VS Code, `--ports`)
No ports are published by default. `claudy jupyter` (8888), `claudy vscode` (8000) and `claudy --ports ...` bind the listed ports to `127.0.0.1` on the host, but on WSL2 `localhost` is forwarded to Windows, so any local Windows process or browser tab can reach them. Jupyter and VS Code use a token, and anyone with it can run code in the container. A dev server on a `--ports` port usually has no authentication at all, so anything local, including a malicious web page in your browser making requests to `localhost`, can talk to it. Publish ports only for the session that needs them.

The other direction matters as much: **opening a page served from the container runs Claude-written (or dependency-supplied) code in your own browser, outside the sandbox**, with that browser's network position and logins. Such a page can:

* reach other services on your machine and local network, including other projects' dev servers or Jupyter, with which pages on `localhost` share browser state;
* cause actions on websites you are logged into;
* show fake login pages, and offer downloads that run as your Windows user if you open them;
* exploit a browser vulnerability, which escapes the claudy sandbox entirely.

Use a **separate browser profile** (or a separate browser) for pages from `claudy`: not logged into anything, without a password manager or extensions, and not used for anything else. Don't open downloads from such pages, close the page when done, and don't run `claudy jupyter` for one project while browsing an untrusted dev server from another. Where possible, test from inside the container instead (`curl`, or a headless browser installed in the project's environment).

VS Code in the browser (`claudy vscode`) is such a page too, and a large one: the editor, and every extension's views, run in your browser, and the files it shows were written by Claude. Its extensions run inside the container with Claude's access (project, deploy key, Claude login, network) and are kept in a per-project volume that, like `.conda_env`, persists between sessions and does not show up in `git diff`; something in the container can change them, and they then run each time you open the editor. Use the same separate browser profile, add only extensions you trust, and remove the volume when in doubt. Claude sessions started in its terminals have the same sandbox as plain `claudy`.

### Human factors
The dedicated distro is only a launcher; running project code there (tests, dev servers, `make`) bypasses the container entirely. Guard rails make that harder to do by accident (README, *Guard rails against running code on the distro*): apt refuses SSH and development tools, the shell marks itself as the host, and `/tmp` and `/dev/shm` are `noexec`. They do not stop a user with `sudo`. The sandbox makes broad permission modes (such as auto-approving tool use) less risky, not safe. Don't put secrets you wouldn't give Claude into a project (`.env`, tokens, keys), and don't paste the `sudo` password into any session.

## This document is public

`SECURITY.md` is published on GitHub, so assume an attacker has read it, and that Claude can read it too whenever this repository is mounted (as when working on the sandbox itself). That is acceptable because none of the protections depend on secrecy: the weaknesses listed here are generic to containers, and a model or attacker can find them without this file. It describes risks at the level needed to judge and mitigate them, not how to carry them out. Still:


* **Documentation can inspire.** An agent that reads this file learns about channels and weaknesses it would not otherwise have considered, and an over-eager agent might try one as a "workaround" when something is blocked, without the user ever having suggested it. To keep that exposure small: the file is not part of the image, the in-container instructions don't point agents to it and tell them to report blocked actions instead of working around them, it opens with a note for agents, and it avoids recipes. Don't paste it into sessions on other projects or add it to a project's context, and when Claude works on this repository, read its changes to this file with that in mind.
* **Keep it free of recipes**: describe what can happen and what to do about it, not exact commands, conditions or file locations that would help someone carry an attack out.
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
| | Replacement of the local `claudy` image by something running as your user on the host |
| | Isolation between Claude sessions or code bases that must not see each other (shared config volume, same user and kernel) |
| | Tampering in `.conda_env` or the project's VS Code volume, which persist between sessions and are not in `git diff` |
| | Pages from the container opened in your browser (they run outside the sandbox, with your browser's logins and `localhost` access) |

## Reporting

Report suspected vulnerabilities in this repository privately through GitHub security advisories on https://github.com/stain/claudy, rather than a public issue.
