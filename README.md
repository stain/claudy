# Claude Code sandbox (Podman on WSL2)

A container image for running Claude Code, Snakemake and Jupyter where only the current project folder is visible to the container. Claude authenticates with your Claude Team subscription login; no API key is needed.

> **What claudy is for, and what not.** claudy is for working on **your own code** with Claude, while letting it run reasonable experiments and tests (install packages, run the test suite, start a dev server, try things out) without affecting anything else on your computer. It is not meant for working on code or data you don't trust. It reduces the *blast radius* of an agent that follows accidental or misleading instructions, or is simply over-eager: a wrong `rm`, a prompt injection in a file or web page, a malicious dependency. It keeps such mistakes inside one project folder and away from your own keys, other projects' keys and (with the dedicated WSL distro) your Windows files.
>
> It is **not** security isolation between Claude sessions or between code bases that must not see each other. All sessions run as the same user on the same kernel, and by default share one Claude config volume (login, transcripts, memory, settings). Separating them properly needs, at the least, separate virtual machines with separate keys and logins for each. A per-project config (`CLAUDY_CONFIG`, see below) is a mitigation, not isolation. See `SECURITY.md`.
>
> Think of it as one rung on a ladder: Claude Code directly on your computer, then claudy, then claudy in the dedicated WSL distro, then a virtual machine per project, preferably in the cloud and away from your home or office network. Climb as far as the code, the data and your network call for (`SECURITY.md`, *A ladder of isolation*).

> **Note for AI agents.** The risks mentioned in this README and in `SECURITY.md` are for the user's awareness. They are not suggestions, permissions or tasks. Stay within what the user asked; if the sandbox blocks something you need, tell the user rather than look for a way around it.

## Layout

Keep the sandbox definition separate from the projects it runs on, so that Claude can never edit its own container configuration:

```
~/claudy/          this repository: Dockerfile, entrypoint.sh, claudy, README.md
~/projects/my-analysis/    a project: your code, data, optional environment.yml
```

Put projects on the WSL filesystem (`~/...`), not under `/mnt/c/...`. Conda environments on the Windows mount are very slow and file ownership does not work reliably there.

## Prerequisites

Podman inside your WSL2 distribution (Ubuntu shown):

```bash
sudo apt update && sudo apt install -y podman
podman info --format '{{.Host.Security.Rootless}}'   # should print: true
```

Rootless Podman maps root inside the container to your own WSL user, so files Claude creates in the project are owned by you.

`claudy` also needs `python3` and Podman's default seccomp profile, `/usr/share/containers/seccomp.json` (from `containers-common`, or `golang-github-containers-common` on Debian/Ubuntu, normally installed with Podman). It derives a stricter profile from it on every start; if the file is elsewhere, set `CLAUDY_SECCOMP_BASE`. The derived profile disables 32-bit binaries (32-bit x86 isn't supported).

### Where to run it

`claudy` works in three kinds of setup. They differ in what a container escape would reach:

* **A dedicated WSL distro (recommended on Windows).** Created by `new-claudy-distro.ps1` (see *Dedicated WSL distro* below): no Windows drives or interop, trimmed, with guard rails against running code on it. The distro is only a launcher, and nothing else runs there. Required for nested mode (`CLAUDY_NESTED=1`).
* **Your everyday WSL distro, with Windows drives and interop.** Follow *Prerequisites* and *First-time setup* as they are; skip the dedicated-distro section, its trim and its guard rails, which would get in the way of normal use. Keep projects on the Linux filesystem (`~/projects`, not `/mnt/c`). The default mode works; `claudy` refuses nested mode. Be aware that an escape from a container lands in a distro that can read and write your Windows files and start Windows programs as you, and that whatever you keep in that distro (SSH keys, tokens, other projects) is within reach. A dedicated distro costs little next to your everyday one: you can run both, with `claudy` only in the dedicated one.
* **Plain Linux (no WSL).** Follow *Prerequisites* (with your distribution's package manager) and *First-time setup*; there is no Windows side to protect, so skip the dedicated-distro section. Nested mode works without the WSL checks. An escape lands as your Linux user, with your home directory, SSH keys and other projects. For more separation, create a separate Linux user just for `claudy` and its projects (rootless Podman needs a subuid range for it, which `adduser`/`useradd` usually adds), and keep your own keys and credentials out of that account.

A planned two-user layout for the dedicated distro (*Future work* in `CLAUDE.md`) will stay optional: `claudy` keeps working for a single user in the setups above.

## First-time setup

### 1. Get the repository and build the image

```bash
git clone https://github.com/stain/claudy.git ~/claudy
cd ~/claudy
podman build -t claudy .
```

Or run `make` in `~/claudy`, which does the same build after two checks: it stops with a hint when `podman` isn't installed, and on WSL it warns when the distro doesn't follow *Where to run it* (Windows drives mounted, interop enabled, or the repository on a Windows drive). The warning doesn't stop the build, as an everyday distro is a supported setup. `make rebuild` is the full rebuild from *Updating Claude Code*; pass build arguments with `make BUILD_ARGS='--build-arg WITH_VSCODE=0'`. The dedicated distro has no `make` (its apt pin refuses it, see *Guard rails*), so use `podman build` there.

The repository is public, so the HTTPS clone needs no credentials (use it rather than `git@github.com:...`, which needs an SSH key). Update later with `git -C ~/claudy pull`, then rebuild the image. The pulled `claudy` takes effect at once, the image only after the rebuild; `claudy` warns at start when `Dockerfile`, `entrypoint.sh` or `etc-claude-code/CLAUDE.md` is newer than the image.

The `Dockerfile` uses a fully qualified base image (`docker.io/library/node:22-slim`), so Podman needs no registry configuration. The build installs git, ssh, jq, zip/unzip, patch, build tools and an editor alongside Claude Code and Miniforge, and takes a few minutes the first time.

### 2. Install the launcher script

Link `claudy` into `~/bin`, so it stays in sync with this repository:

```bash
mkdir -p ~/bin
ln -s ~/claudy/claudy ~/bin/claudy
```

On Ubuntu, `~/.profile` adds `~/bin` to `PATH` if the directory exists at login. If you have just created it, open a new WSL terminal (or run `export PATH="$HOME/bin:$PATH"`) and check with `command -v claudy`.

`claudy` mounts the current directory at `/projects/<folder>-<hash>` (linked from `/workspace`) and the `claude-config` volume at `/claude-config`, and nothing else. The per-folder path lets Claude Code keep each project's conversations and memory apart. It also runs the container with a stricter seccomp profile than Podman's default, derived from it on each start into `~/.cache/claudy/seccomp.json` (see `SECURITY.md`); this needs `python3` on the host. It refuses to run from `/`, `$HOME` or the Windows drive.

Make sure `ANTHROPIC_API_KEY` is not exported in your shell. If it were set, Claude Code would try API-key authentication instead of your Team subscription.

### 3. Start Claude and log in

```bash
cd ~/projects/my-analysis
claudy
```

If the project contains `environment.yml`, the conda environment is created first in `.conda_env/`. This takes a few minutes the first time.

Claude Code then asks for a login method:

1. Choose the **Claude subscription** login (not Claude Console / API).
2. Open the printed URL in your Windows browser, signed in with the account that belongs to your Claude Team organisation.
3. Select your Claude Team organisation and click **Authorize**.
4. The browser cannot redirect back into the container, so it shows a code. Paste it at the `Paste code here if prompted` prompt.

Run `/status` in Claude to confirm the account and organisation. If it picked the wrong organisation, run `/login` and choose again.

The credentials are stored in the `claude-config` Podman volume. They survive `--rm`, reboots and image rebuilds, so you only log in once.

### Shared or per-project Claude config

By default every project uses the same `claude-config` volume: one login, and shared settings, plugins and history. That is what most people want. The trade-off is that every session can read, and change, what other sessions left there: the conversations of all your projects (including code, data and any secret that appeared in them), your prompt history, Claude's memory (each project has its own folder, but all are in the same volume), the settings every session loads, and the login. So a session misled in one project could see your other projects' work, or influence them later. Details in `SECURITY.md`, *Cross-talk and leakage through the shared config volume*. Keeping it shared is fine when the projects belong together: your own work, with data of similar sensitivity. Give a project its own volume when it holds data other projects shouldn't see (confidential or someone else's data), or when it works on untrusted material, such as reviewing third-party code:

```bash
CLAUDY_CONFIG=claude-config-myproject claudy
```

Use the same name every time you start that project (an alias helps), and log in once for it. This is a mitigation, not isolation: the volumes are still owned by your user, so an escape from any container, or anything else running as you, can read them all. Code bases that must not see each other belong in separate virtual machines with their own keys and logins. Either way, keep secrets out of sessions: don't paste them, and don't have Claude print `.env` files or tokens, because whatever appears ends up in the transcript. Decide before the first session: a project's conversations and memory stay in the volume it started with, so moving them to another volume later is manual work.

## Everyday use

From any project folder:

```bash
claudy                       # Claude Code
claudy bash                  # a shell in the same environment
claudy snakemake --cores 4   # any command
claudy pubkey                # this project's SSH public key
claudy jupyter               # Jupyter Notebook on http://localhost:8888 (needs notebook in environment.yml, see below)
claudy vscode                # VS Code in the browser on http://localhost:8000 (see below)
claudy --ports 8080,5173     # Claude Code, with these ports reachable on http://localhost:<port> (see below)
```

The project's conda environment (`/workspace/.conda_env/bin`) is on `PATH` for every command, so there is no need for `conda activate`. The entrypoint and interactive shells (via `/etc/bash.bashrc`) also activate it when it exists, and `conda activate` works in those shells.

Ctrl-Z suspends Claude Code to a bash prompt inside the container (not your host shell): `fg` brings it back, and leaving Claude ends the container as before. This also applies to `claudy claude ...`, for example `claudy claude --continue`. Claude runs as a job of that shell because the container's first process can't be suspended; a host shell is one Ctrl-Z can't reach, so open another terminal for that.

## Conda environment

`environment.yml` lives in the project, not in this repository. On each start the entrypoint:

* creates `.conda_env/` if it does not exist;
* runs `conda env update --prune` if `environment.yml` is newer than the environment;
* otherwise does nothing;
* writes `.conda_env/.gitignore` (containing `*`) so the environment is never committed, and activates the environment for the command it starts.

The image uses Miniforge (conda-forge). Do not add the Anaconda `defaults` channel: it requires accepting Anaconda's Terms of Service and is subject to its organisational licensing terms. Use:

```yaml
channels:
  - conda-forge
  - bioconda
```

The environment is ignored by git automatically; no entry in the project's `.gitignore` is needed.

The image allows only these two channels for `conda install` and `conda create`; `conda env create -f` does not enforce this, so check the `channels:` of an `environment.yml` yourself.

Treat `.conda_env` as belonging to the sandbox: don't activate it or run its programs on the host, and don't let a host IDE use it as an interpreter. Claude can change it without that showing in `git diff`; delete it when in doubt and it is rebuilt on the next start (see `SECURITY.md`, *The project conda env is persistent and not reviewed*).

## Opening ports (`--ports`)

By default no container port is reachable from your machine, so a web app or dev server that Claude starts inside the container can't be opened in your browser. `--ports` publishes the listed ports under the same number on your host's `127.0.0.1`:

```bash
claudy --ports 8080                  # Claude Code, port 8080 reachable as http://localhost:8080
claudy --ports 8080,5173 bash        # a shell, two ports
claudy --ports=3000 --ports 8080     # the option can be repeated
```

* Put `--ports` before the command; it combines with any command, including `jupyter`.
* The server must listen on `0.0.0.0` inside the container, not `127.0.0.1`/`localhost` (most dev servers default to localhost), e.g. `python -m http.server 8080 --bind 0.0.0.0`.
* Use ports 1024 or higher: rootless Podman can't publish lower ones by default, and nested containers can't listen on them.
* Ports are fixed when the container starts. To add one, exit and restart with it; `claudy --ports 8080 claude --continue` resumes this project's most recent conversation (`claude --resume` lets you pick one). Conversations are kept per project folder, so moving or renaming the folder starts a fresh history. Claude knows this and asks you to restart when it needs a port, explaining why. Anything not saved in the project (temporary installs, background processes) is lost on restart.
* Inside the container, `CLAUDY_PORTS` lists the published ports.
* While published, the port is reachable by any program on your machine, including web pages in your browser and, on WSL2, the Windows side. Dev servers rarely have authentication, so publish ports only for the session that needs them. See `SECURITY.md`.
* **Opening the page runs Claude's code in your browser, outside the sandbox**, with your browser's logins and its access to your machine and network (see `SECURITY.md`, *Published ports*). Use a **separate browser profile** for `claudy` pages, logged into nothing and without a password manager or extensions, and don't open files they download. Where you can, let Claude test with `curl` or a headless browser inside the container instead.

## Jupyter Notebook

The image does not include Jupyter. `claudy jupyter` runs `jupyter notebook` from the project's conda environment, so add `notebook` to the project's `environment.yml`, for example:

```yaml
channels:
  - conda-forge
  - bioconda
dependencies:
  - python=3.12
  - notebook
  # your analysis packages, e.g.
  - pandas
  - matplotlib
```

Then, from the project folder:

```bash
claudy jupyter                       # http://localhost:8888 (published automatically), open the token URL it prints
claudy --ports 8050 jupyter          # also publish 8050, e.g. for a Dash app started from a notebook
claudy --ports 8888                  # Claude Code with 8888 published, so Jupyter can run alongside Claude
```

With the last form, start Jupyter inside the session (ask Claude, or run it in a `!` shell command) so that it listens on all interfaces: `jupyter notebook --ip=0.0.0.0 --port=8888 --no-browser --allow-root`. Ask Claude for the token URL, or run `jupyter server list`; it shows the container's hostname, so open it as `http://localhost:8888/?token=...`. Claude can then work on the same notebooks while you have them open. The server stops when you exit Claude.

Notebooks are saved in the project folder. The Jupyter server runs with the same isolation as Claude (only the project folder, its own SSH key), and anyone with the token URL can run code in the container. Notebook output that Claude produced runs in your browser when you open it, so the same advice as for `--ports` applies: use a separate browser profile for it. Without `notebook` in the environment, `claudy jupyter` fails with `jupyter: not found`.

## VS Code in the browser (`claudy vscode`)

`claudy vscode` runs VS Code's web server inside the container and publishes its port on your host's `127.0.0.1`, like `--ports` does:

```bash
claudy vscode                          # port 8000; open the URL with the token it prints
CLAUDY_VSCODE_PORT=8001 claudy vscode  # another port (1024 or higher), e.g. for a second project
claudy --ports 5173 vscode             # also publish 5173, e.g. for a dev server started in a VS Code terminal
```

* **Open the printed URL**, which carries a token that is new on every start; without it the server refuses the connection. Its host name, `vscode-<project>.localhost`, is the project's own, so the browser keeps the token's cookie away from dev servers, Jupyter and other projects on `localhost` (Chrome, Edge and Firefox send any `*.localhost` name to your machine). Use the **separate browser profile** from *Opening ports*: VS Code, and the extensions you add, run their pages in your browser.
* **Terminals in VS Code are inside the container**, with the same environment as `claudy bash`: the project's conda env, git author, SSH key and Claude login. Without `CLAUDY_GIT_*`, Source Control commits with your git config rather than the sandbox placeholder (*Commit author*). Run `claude` in one to use Claude Code next to the editor; it keeps the same conversations and memory as plain `claudy`, as it runs in the same project folder. Inside, `CLAUDY_VSCODE_PORT` tells Claude that port is taken.
* **Stopping**: press Ctrl-C in the host terminal where `claudy vscode` runs. That ends the editor and every terminal in it, including Claude sessions. Closing the browser tab doesn't: the server keeps terminals alive, so you can reload the page.
* **Keyboard**: the browser keeps some shortcuts, such as Ctrl-W (closes the tab, where a terminal would delete a word), Ctrl-T and Ctrl-N. Installing the page as an app (*Install* in Chrome or Edge) gives most of them to VS Code.
* **Downloads and storage**: the image contains the VS Code command-line tool. On first start it downloads the VS Code server from Microsoft, several hundred MB, into a per-project volume, `claude-vscode-<folder>-<hash>`, which also keeps installed extensions. `podman volume rm` it to start over. Extensions are separate per project on purpose: a shared volume would let an extension installed in one project run in all of them.
* **Licence**: VS Code Server is under Microsoft's licence terms, which `claudy vscode` accepts on your behalf when it starts the server (it prints the link). Telemetry is turned off. If you don't want it in the image, build with `--build-arg WITH_VSCODE=0`.
* Extensions run inside the container, with the same access as Claude: the project folder, its SSH key, the Claude login and the network. Install only those you trust.
* **It looks like your local VS Code, but runs in the container.** Accounts you sign in to, Settings Sync, tokens typed into its terminals, and files you drag in all end up inside, within Claude's reach; files you download from it leave the sandbox. If the browser asks whether the page may read the clipboard, block it: keyboard paste still works, and allowing it lets the editor and its extensions read whatever you copy. Keep sync and accounts signed out, and don't open the folder in your desktop VS Code without reviewing `.vscode` (`SECURITY.md`, *VS Code in the browser*).
* This is not VS Code Dev Containers (see *Security notes*): your desktop VS Code, its SSH agent and git credentials are not involved.

## Git, GitLab and GitHub (SSH)

Your own SSH keys and git credentials are never visible to the container. Instead, each project folder gets **its own SSH key**, stored in a per-project Podman volume (`claude-ssh-<folder>-<hash>`, mounted at `/root/.ssh`). Containers for different projects cannot see each other's keys.

The key is generated on the first start and its public key is printed. To show it again:

```bash
claudy pubkey
```

Add it in GitLab as a **deploy key** for that one repository (*Settings → Repository → Deploy keys*), with *Grant write permissions* only if Claude should push. Do not add it to your user account: a user key would give the container access to every repository you can reach.

On **GitHub** do the same under the repository's *Settings → Deploy keys* (tick *Allow write access* only if Claude should push). GitHub accepts a given deploy key on one repository only, and refuses a key that is already attached to a user account. Check it works with `ssh -T git@github.com` (it should greet the repository, e.g. `Hi owner/repo!`) and use an SSH remote (`git remote set-url origin git@github.com:owner/repo.git`) rather than `https://`.

### Checking out a repository

Each repository gets its own folder, and that folder *is* the repository: the folder you start `claudy` in becomes `/workspace`, so the checkout must land directly in it, not in a subfolder. Clone over SSH from inside `claudy`, so no HTTPS password or token is ever typed into (or stored by) the container.

```bash
mkdir -p ~/projects/project5 && cd ~/projects/project5   # new, empty folder for this repository
claudy pubkey                                            # first start: generates this folder's key and prints it
```

**Pause here** and add the printed key as a deploy key on that one repository (see above). Until it is added, cloning fails with `Permission denied (publickey)`. Check that it works, then clone into the current folder (note the final `.`) and start Claude:

```bash
claudy ssh -T git@github.com                              # "Hi owner/repo! You've successfully authenticated..."
claudy git clone git@github.com:owner/repo.git .          # or git@gitlab.com:group/repo.git .
claudy                                                    # Claude Code in the checkout
```

The result:

```
~/projects/project5/            = /workspace in the container = the repository root
├── .git/
├── environment.yml             (if the project has one; .conda_env/ is created next to it on the next start)
└── ...
```

Notes:

* **Clone into `.`**, not `claudy git clone git@...:owner/repo.git` without it: that would put the checkout in `~/projects/project5/repo`, one level down, so Claude would start outside the repository and `environment.yml` would not be found.
* **Don't run `claudy` from `~/projects` itself**, e.g. to clone several repositories at once. That mounts every project into one container, under one shared key named after `~/projects`, which undoes the per-project separation.
* The key is tied to the folder's path, so don't move or rename the folder afterwards, or it gets a new key and the deploy key must be added again.
* Starting `claudy` in a subfolder of a project makes the subfolder a project of its own, with its own key, conda env and conversations. `claudy` warns when a parent folder was already used as a project and waits 5 seconds, so you can press Ctrl-C, then starts anyway.
* `git clone` into `.` needs an empty folder. `claudy pubkey` writes nothing into it (the key lives in a Podman volume), so the order above works.
* If you cloned with `https://` elsewhere, switch it with `git remote set-url origin git@host:owner/repo.git`. Don't enter HTTPS credentials in the container: a stored password or token would be readable by Claude and usable on every repository your account can reach.

Deploy keys only give git access. They cannot open merge/pull requests or issues through an API.

Notes:

* The private key is readable by anything running in the container, including Claude. A write-enabled deploy key lets Claude push to **any branch** of that repository, so protect the default branch (`main`) and other important branches:
  * **GitHub:** *Settings → Rules → Rulesets* (or *Branches → Branch protection rules*) for `main`: require a pull request before merging, block force pushes and block deletion. Don't add the deploy key to a bypass list.
  * **GitLab:** *Settings → Repository → Protected branches*: set *Allowed to push and merge* for `main` to *No one* (merge through merge requests) and leave *Allowed to force push* off. Deploy keys can only push to a protected branch if you allow them explicitly there.

  Claude is instructed not to push to `main` unless you ask, but branch protection is what enforces it, also against a prompt injection.
* The key has no passphrase, and no SSH agent is forwarded.
* Host keys are recorded on first contact (`StrictHostKeyChecking accept-new`) and kept in the same volume. For a self-hosted GitLab this works the same way.
* To revoke: delete the deploy key in GitLab, and `podman volume rm` the volume (`podman volume ls` lists them). Removing it makes the next start generate a new key.
* Keys belong to the WSL distro they were generated in. Replacing or re-creating the distro gives every project a new key; add the new ones and delete the old deploy keys (see *Replacing an existing distro deletes its files*).
* Commits made in the container have their own author; see *Commit author* below.

### Commit author

Commits made in the container are authored and committed as `Claude Sandbox <claude-sandbox@localhost>` by default. Override it for one run with `CLAUDY_GIT_NAME="Your Name" CLAUDY_GIT_EMAIL=you@example.org claudy` (also with `claudy vscode`, `claudy bash` and the other commands), or change the default by editing the `GIT_*` variables in the `Dockerfile` and rebuilding. While the default is in use, `claudy` warns at start and waits 3 seconds, so you can press Ctrl-C (set both variables, even to the default, to silence it), and Claude warns you once per session before its first commit and tells you how to restart with your own identity; it doesn't change the author itself. For commits you make yourself in a terminal (`claudy bash`), a notice says the same when it opens.

With `claudy vscode`, the default labels only Claude's commits (and those typed in VS Code's terminals); VS Code's Source Control commits with your git config instead. As `/root` isn't kept, set it in the project once: `git config user.name "Your Name"` and `git config user.email you@example.org` (written to `.git/config`, which git on the host uses too). Without it, Source Control refuses to commit and asks who you are, rather than using the placeholder or guessing. `claudy vscode` prints at start which identity Source Control will use. To do this, it gives the placeholder to the terminals and to the Claude Code extension through VS Code's machine settings in the project's VS Code volume (`terminal.integrated.env.linux`, `claudeCode.environmentVariables`), replacing those `GIT_*` entries on every start. With `CLAUDY_GIT_NAME`/`CLAUDY_GIT_EMAIL`, everything uses that identity, as in plain `claudy`.

Things to weigh:

* **Whose name goes on Claude's work.** The default keeps sandbox commits recognisable in `git log` and on the forge, which helps review: you can see what came from the container and check it before merging. With your own name, Claude's commits look like your own work. That can be what you want (you take responsibility for them, and some projects expect a real author), but then rely on the `Co-Authored-By: Claude …` trailer that Claude Code adds, and review as carefully as if you hadn't written them yourself.
* **Matching commits to your account.** GitHub and GitLab link commits to an account by email. `claude-sandbox@localhost` links to no one. To have commits count as yours without publishing your address, use the forge's no-reply address (shown in your account's email settings). If GitHub is set to block pushes that expose your private email, a commit with that address is rejected.
* **Claude can read it.** An identity from `CLAUDY_GIT_*` or the project's git config is visible to Claude like any other file or variable in the container, so it can end up in what Claude sends out (see `SECURITY.md`, *Your name and email in the container*).
* **Keep it out of this repository.** Your name and email are personal data and this repository is public: set `CLAUDY_GIT_NAME`/`CLAUDY_GIT_EMAIL` in a shell alias or your own startup file, not in the `Dockerfile` of a fork you publish.
* **The environment wins over git config.** The variables override `user.name`/`user.email` in the project's `.git/config` and in any git config Claude writes, so the author can't be changed from inside the container unless Claude sets the variables in a command itself. It is still just text: anyone, Claude included, can put any name on a commit, so treat author fields as labels, not proof.
* **Set it per project if identities differ.** Exported in your shell, the variables apply to every project you start from it. Use one alias per project (or set them on the command line) if, say, work and personal repositories need different authors.
* **No commit signing in the container.** There is no GPG or signing key inside, and there shouldn't be: don't add the project's SSH key as a signing key on your account, or anything in the container could produce commits marked *Verified* as you. If a branch requires signed commits, keep that rule on the default branch and let the forge sign when you merge the pull request (a squash or merge commit made in the web interface), or re-sign the commits yourself on the host after review.
* **Changing the author afterwards** rewrites the commits; do it on the host before they are pushed, or only on a branch nobody else has fetched.

## Dedicated WSL distro for nested containers (Windows only)

Normal use doesn't strictly need this. Podman inside the container works without it, but uses user namespaces heavily (see `SECURITY.md`, *Nested containers*), so a dedicated distro is recommended if Claude will run containers, and required for `CLAUDY_NESTED=1`, which also passes `/dev/fuse` into the container and enlarges the kernel attack surface further. On WSL2 an escape would land in a distro that can read your Windows drives and start Windows programs as you, so for nested mode use a **separate WSL distro that has neither**.

On a plain Linux host there is no Windows side to protect: skip this section (see *Where to run it*). Nested mode is still opt-in and off by default, and `claudy` only checks the WSL conditions when it detects WSL.

### Automated: `new-claudy-distro.ps1`

`new-claudy-distro.ps1` does steps 1 to 5 below, plus the first-time setup, in one go from Windows. It installs the distro, creates your user (asking for its password), writes `/etc/wsl.conf`, installs Podman, git and vim, removes the packages listed in step 4, restarts the distro, checks that the Windows drives and interop are gone, then clones this repository over HTTPS, builds the image and links `~/bin/claudy`. The Linux part is plain bash embedded in the script and piped into `wsl.exe`; read it before running.

Download it from GitHub (it is a single file), read it, then run it from PowerShell:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/stain/claudy/main/new-claudy-distro.ps1 -OutFile new-claudy-distro.ps1
notepad new-claudy-distro.ps1
powershell -ExecutionPolicy Bypass -File .\new-claudy-distro.ps1 -User yourname
```

**Read the script before you run it.** It is a single commented text file: the header (shown by `Get-Help .\new-claudy-distro.ps1 -Full`) lists its seven steps, what it changes on Windows (only the new distro) and what it downloads, and each step in the body says what it does and why. In particular, check that:

* the only download source it uses is this repository on GitHub (`-RepoUrl`), apart from the Ubuntu image and packages and what the `Dockerfile` fetches;
* the bash sections (`$base`, `$trim`, `$check`, `$build`) match the manual steps 1 to 5 below, which explain the same settings in more detail;
* nothing in it touches Windows beyond `wsl.exe` creating and starting the new distro.

If anything is unclear or differs from this README, don't run it; follow the manual steps instead, or ask.

**Warning:** the script runs as you on Windows and as root inside the new distro, and `-ExecutionPolicy Bypass` skips the only check Windows would do, so reading it is the check. Only take it from this repository on GitHub, over HTTPS as above, not from a fork, a mirror, a link someone sent you, or a copy in a WSL folder or project (`\\wsl.localhost\...`) that Claude or a container could have edited. To run exactly the version you reviewed, replace `main` in the URL with a commit hash from the GitHub history.

Options: `-Branch` (default `main`; the branch of this repository to check out and build, e.g. to test a pull request), `-Name` (default `claude-sandbox`), `-Distro` (default `Ubuntu-26.04`), `-Location` (folder for the virtual disk), `-SkipTrim`, `-SkipBuild`. It refuses to touch an existing distro of the same name. Afterwards, back up the result (`wsl --export claude-sandbox claude-sandbox.tar`) and continue with *Keep Claude away from the distro itself* below. The manual steps follow.

### Replacing an existing distro deletes its files

`wsl --unregister <name>` (needed before reusing a name, or when restoring a backup with `wsl --import`) deletes the distro's whole virtual disk. Nothing inside it survives:

* your projects (`~/projects/...`), including uncommitted changes, unpushed commits, branches and stashes that exist only there, and data files that aren't in git;
* the Podman volumes: `claude-config` (your Claude login and session history), every project's `claude-ssh-*` key (new keys are generated, so every deploy key must be added again and the old ones deleted, see below) and `claude-containers-*` (nested images);
* `~/claudy` and the built images (cheap to recreate).

So before replacing a distro:

1. Inside the old distro, commit and push every project you want to keep (`git status` and `git log @{u}..` in each), or copy the files out.
2. Back up the whole distro from PowerShell, so nothing is lost if you missed something: `wsl --export <name> C:\wsl\<name>-old.tar`.
3. Prefer creating the new distro under a **new name** (`-Name claude-sandbox2`) and keep the old one until everything is moved. `new-claudy-distro.ps1` refuses to overwrite an existing distro for this reason.

To move projects over directly, from PowerShell (`cmd /c` keeps the pipe binary-safe; `.conda_env` is rebuilt from `environment.yml` on the first start, so it is left out):

```powershell
cmd /c "wsl -d <old> -- tar -C ~ --exclude=.conda_env -cf - projects | wsl -d claude-sandbox -- tar -C ~ -xf -"
```

Folder paths stay the same, but the per-project SSH volumes are not copied (and should not be: keys stay with the distro they were made in), so each project gets a new key on its first start. Log in to Claude again in the new distro.

**Replacing the distro means replacing the SSH deploy keys.** For every project:

1. In the new distro, run `claudy pubkey` in the project folder and add the key as a deploy key on that repository (see *Git, GitLab and GitHub*), with write access only if Claude should push.
2. In the repository's deploy key settings, **delete the old distro's key**. It is still valid: it lives on in the old distro and in any `wsl --export` backup of it, which contain the private keys in plain text.
3. Once everything is moved, `wsl --unregister` the old distro and delete or securely store its backup `.tar`.

GitHub refuses a deploy key that is already used on another repository, and each key is per project, so there is nothing to reuse; deploy keys are named in the repository settings, so give the new one a name that says which distro it belongs to (e.g. `claude-sandbox2 my-analysis`).

### 1. Create the distro (from PowerShell)

```powershell
wsl --update
wsl --install -d Ubuntu-26.04 --name claude-sandbox
```

`--name` needs a recent WSL (2.4.4 or newer, see `wsl --version`). Without it, export and re-import an existing Ubuntu: `wsl --export Ubuntu ubuntu.tar` then `wsl --import claude-sandbox C:\wsl\claude-sandbox ubuntu.tar`; an imported distro starts as root, so create the user as described under *If you are root* below.

When the installation finishes, Ubuntu asks you to create a Linux username and password, then opens a shell as that user:

* The username can be anything (it doesn't have to match your Windows name). It becomes the default user of this distro.
* Set a password: it is local to this distro, unrelated to your Windows login, and `sudo` needs it.

*If you are root* (imported distro, or you started it with `wsl -d claude-sandbox -u root`): create the account yourself with `adduser <name>` followed by `usermod -aG sudo <name>`, and add `[user]` with `default = <name>` to `wsl.conf` below.

### 2. Configure it

Inside the distro, as your new user, open the file with `sudo nano /etc/wsl.conf` and put this in it:

```ini
[boot]
systemd = true

# No /mnt/c, /mnt/d ...
[automount]
enabled = false
mountFsTab = false

# Cannot start Windows programs (cmd.exe, powershell.exe)
[interop]
enabled = false
appendWindowsPath = false
```

Save (Ctrl+O, Enter, Ctrl+X). Even with interop disabled, WSL keeps its handler for Windows programs registered (why that matters: `SECURITY.md`, *WSL2 is not a virtual machine boundary to Windows*). Remove it on every boot:

```bash
sudo tee /etc/systemd/system/wsl-remove-interop.service >/dev/null <<'EOF'
[Unit]
Description=Remove the WSL interop binfmt handler (interop is disabled in /etc/wsl.conf)
After=systemd-binfmt.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /proc/sys/fs/binfmt_misc/WSLInterop /proc/sys/fs/binfmt_misc/WSLInterop-late; do if [ -e "$$f" ]; then echo -1 > "$$f"; fi; done'

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable wsl-remove-interop.service
```

Then restart the distro from PowerShell so the settings take effect:

```powershell
wsl --terminate claude-sandbox
wsl -d claude-sandbox
```

Check that the isolation works inside the distro:

```bash
ls /mnt/c                   # empty or missing
cmd.exe                     # command not found
ls /proc/sys/fs/binfmt_misc   # no WSLInterop or WSLInterop-late
```

### 3. Install and use

Inside the distro, install the prerequisites (`sudo apt update && sudo apt install -y podman`), then follow *First-time setup* above: it clones this repository from GitHub over HTTPS, builds the image and links `claudy`. That is the only thing the isolated distro fetches from outside, so it needs no keys. The image includes Podman by default (build arg `WITH_PODMAN=1`, `0` leaves it out), preconfigured for nested use (subuid/subgid range, host network and PID namespace). Podman works without `/dev/fuse` using the `vfs` storage driver; the entrypoint switches to `overlay` on `fuse-overlayfs` when `/dev/fuse` is present, i.e. with `CLAUDY_NESTED=1`. Nested mode uses the same image; start it with the flag:

```bash
cd ~/projects/my-analysis
CLAUDY_NESTED=1 claudy
```

Notes:

* Keep projects on the distro's own filesystem (`~/projects`). Copy files in and out through `\\wsl.localhost\claude-sandbox\home\youruser` in Windows Explorer.
* Without interop the login URL cannot open a browser: copy it from the terminal into your Windows browser by hand (the README's login steps already do this).
* `localhost:8888` for Jupyter is still forwarded to Windows.
* All WSL2 distros share one Linux kernel and VM. A separate distro keeps your Windows files out of reach of your user, but it is not a separate virtual machine: root in the distro can still mount them, so the protection depends on nothing reaching root there (see `SECURITY.md`, *WSL2 is not a virtual machine boundary to Windows*). The container can also still reach the network.
* `claudy` and the `Dockerfile` run with your user's rights on the host, so `git pull` only from a source you trust, and read `git diff` of those two files after pulling.
* `claudy` refuses nested mode on WSL while `/mnt/<drive>` or interop is active. `CLAUDY_ALLOW_UNSAFE_NESTED=1` overrides this; don't.

### 4. Trim the distro

The sandbox distro only has to start `claudy`: it needs the base system, systemd, `apt` with security updates, `sudo`, Podman and its helpers, `git` to update this repository, and an editor. Compilers, Node.js, Java, TeX and GUI apps belong in the container image or a project's environment, not here. Every extra package is more code running as your user next to the sandbox (setuid binaries, services, update and telemetry agents, and `wsl-pro-service`, which talks to the Windows side), so remove what you don't need.

The list below matches a fresh `Ubuntu-26.04` install from `wsl --install` (about 350 packages remain after trimming); adjust it to what `apt-mark showmanual` shows on yours. If you added packages yourself (compilers, Java, TeX, GUI apps), add them to `extra`.

1. **Back up first**, from PowerShell, so you can restore if something breaks:

   ```powershell
   wsl --export claude-sandbox C:\wsl\claude-sandbox-before-trim.tar
   ```

2. **Look at what is there** (inside the distro):

   ```bash
   apt-mark showmanual                         # packages installed on purpose
   dpkg-query -W -f='${Installed-Size}\t${Package}\n' | sort -n | tail -30   # largest
   snap list                                   # snaps, if snapd is installed
   systemctl list-unit-files --state=enabled   # services started at boot
   ```

3. **Protect what must stay** by marking it as manually installed, so that removing a metapackage (`ubuntu-wsl`, `ubuntu-minimal`) or `autoremove` can't take it along:

   ```bash
   sudo apt-mark manual apt sudo sudo-rs systemd systemd-sysv systemd-resolved init \
     dbus dbus-user-session libpam-systemd wsl-setup ca-certificates locales tzdata \
     unattended-upgrades less vim vim-tiny nano git iproute2 procps nftables \
     podman uidmap passt slirp4netns fuse-overlayfs crun conmon netavark aardvark-dns catatonit
   ```

4. **Remove the metapackages, then the rest.** Removing a metapackage removes nothing by itself, but afterwards `autoremove` drops everything only it pulled in. Simulate first (`-s`) and read the `Purg`/`Remv` lines: none of the packages from step 3 may appear. If one does, take out the package that drags it along (`apt-get -s remove <pkg>` shows what each one would take). Leave out anything from this list you still want; packages that aren't installed are skipped.

   ```bash
   # Metapackages: removing one removes nothing else, but lets autoremove drop what only it pulled in
   meta=(ubuntu-wsl ubuntu-minimal)

   # What a fresh Ubuntu-26.04 WSL install still has after autoremove. Not listed on purpose:
   # cloud-init, chrony, ethtool, gpg, dbus-x11, xdg-user-dirs and python3-* (wsl-setup or
   # the keep list need them), and Essential/required packages such as
   # coreutils, rust-coreutils or gcc-*-base.
   extra=(
     # remote management, telemetry and Windows integration agents (ubuntu-insights is only
     # recommended by wsl-setup; without it, first start doesn't ask about metrics)
     snapd landscape-client landscape-common ubuntu-pro-client wsl-pro-service ubuntu-insights
     apport apport-core-dump-handler software-properties-common ubuntu-release-upgrader-core
     motd-news-config show-motd command-not-found python3-wadllib
     # toolchains and extras the sandbox host doesn't need (the container has its own)
     build-essential xauth byobu screen rsyslog openssh-client rsync wget bc eatmydata
   )
   mapfile -t remove < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "${meta[@]}" "${extra[@]}" 2>/dev/null | awk '$1 == "ii" { print $2 }')
   sudo apt-get -s purge --autoremove "${remove[@]}" | grep -E '^(Purg|Remv) ' | less
   sudo apt-get purge --autoremove "${remove[@]}"
   sudo apt autoremove --purge                 # anything else left unused
   sudo apt purge '~c'                         # leftover config of removed packages
   ```

   Don't try to remove what is left by force: `cloud-init`, `chrony`, `ethtool`, `gpg`, `dbus-x11`, `xdg-user-dirs` and the `python3-*` packages stay because `wsl-setup` or the packages from step 3 depend on them, and Essential packages (`coreutils`, `rust-coreutils`, `gcc-*-base` and other libraries) are part of the base system. Removing them takes `wsl-setup` along, which WSL needs.

   `openssh-client` is removed on purpose: the distro clones this repository over HTTPS, and it must not hold SSH keys (see *Keep Claude away from the distro itself*). Without `ubuntu-release-upgrader-core` there is no `do-release-upgrade`: for a new Ubuntu release, create a fresh distro instead (clone, build, link). Keep `unattended-upgrades`, which installs security updates.

5. **Repeat** `apt-mark showmanual` and remove anything else you don't recognise as needed (`sudo apt purge --autoremove <pkg>`, simulate with `-s` first). Check `systemctl list-unit-files --state=enabled` and `systemctl --failed` again.

6. **Check that everything still works**, after restarting the distro from PowerShell (`wsl --terminate claude-sandbox`, then `wsl -d claude-sandbox`):

   ```bash
   sudo -v                                     # sudo still works
   ls /mnt/c; cmd.exe                          # still isolated (missing / not found)
   git -C ~/claudy pull                        # HTTPS to GitHub works
   podman info --format '{{.Host.Security.Rootless}}'                    # true
   cd ~/projects/my-analysis && claudy bash -c 'podman run --rm docker.io/library/hello-world'
   ```

   If something is broken and you can't fix it, restore the backup from PowerShell (this discards everything done in the distro since the backup, see *Replacing an existing distro deletes its files*): `wsl --unregister claude-sandbox`, then `wsl --import claude-sandbox C:\wsl\claude-sandbox C:\wsl\claude-sandbox-before-trim.tar`. An imported distro starts as root unless `wsl.conf` has `[user]` `default = <name>` (see *If you are root* above).

### 5. Guard rails against running code on the distro

The distro is only a launcher. Project code, tests and dev servers belong in `claudy` containers (see *Keep Claude away from the distro itself*). Three guard rails make the wrong path fail loudly; `new-claudy-distro.ps1` sets them all up. They stop accidents, not a determined user with `sudo`.

* **apt refuses development tools and SSH.** `/etc/apt/preferences.d/claudy-no-dev-tools.pref` pins `openssh-client`, compilers, `make`, Node.js, `pip`/`venv`, Java, Go, Rust, Ruby, Docker and friends to priority -1, so `sudo apt install nodejs` fails with *Package 'nodejs' has no installation candidate*. apt can't say why, and its message may even suggest another package (such as `nodejs-doc`) as a replacement; `apt-cache policy nodejs` shows the pin (`Candidate: (none)`, priority -1). Python itself stays: `wsl-setup`, netplan and `claudy` (to build its seccomp profile) need it.
* **The shell reminds you where you are.** The first interactive shell prints a short guide to starting a project (again any time with `claudy-help`). Interactive shells show a red `[claudy host]` prompt marker, print a warning when you `cd` into a project under `~/projects`, and answer a missing command with a hint to run it through `claudy` instead.
* **`/tmp`, `/dev/shm` and `/run/shm` are mounted `noexec`** at every boot (`claudy-tmp-noexec.service`; WSL mounts `/run/shm` as a separate tmpfs), so a binary downloaded or unpacked there can't be started. apt is told to use `/var/tmp` for package configuration scripts, which would otherwise fail. `~/projects` is deliberately *not* `noexec`: the container's `/workspace` is a bind mount of it and would inherit the flag, breaking every script and conda program inside `claudy`.

To set them up by hand, as root (`sudo -i`):

```bash
# apt refuses to install development tools and SSH here (README, "Guard rails")
cat > /etc/apt/preferences.d/claudy-no-dev-tools.pref <<'EOF'
# claudy sandbox distro: development tools and SSH belong inside claudy containers, not on
# this host (README, "Guard rails"). Deleting this file gives that protection up.
Package: openssh-client openssh-server build-essential gcc g++ clang make cmake nodejs npm python3-pip python3-venv pipx default-jdk default-jdk-headless default-jre default-jre-headless openjdk-* golang-go rustc cargo ruby docker.io docker-ce containerd snapd code
Pin: release a=*
Pin-Priority: -1
EOF

# Shell nudge: a prompt marker, a warning on entering a project, a hint for missing tools
cat > /etc/claudy-host.bashrc <<'EOF'
# claudy sandbox distro: this shell is the host, not the sandbox (README, "Guard rails").
case $- in *i*) ;; *) return ;; esac
_claudy_host_project=
_claudy_host_prompt() {
    case $PS1 in *'[claudy host]'*) ;; *) PS1='\[\e[1;31m\][claudy host]\[\e[0m\] '"$PS1" ;; esac
    case $PWD/ in
        "$HOME"/projects/?*/*)
            local p=${PWD#"$HOME"/projects/}; p=${p%%/*}
            if [ "$p" != "$_claudy_host_project" ]; then
                _claudy_host_project=$p
                printf '\e[1;31mclaudy host:\e[0m run project code in the sandbox: claudy bash, claudy <command>\n' >&2
            fi ;;
        *) _claudy_host_project= ;;
    esac
}
PROMPT_COMMAND="_claudy_host_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
command_not_found_handle() {
    printf '%s: not installed on the claudy host on purpose; run it in the sandbox: claudy %s\n' "$1" "$*" >&2
    return 127
}
claudy-help() {
    cat <<'HELP'
This WSL distro only starts claudy. Your code, tests and tools run inside claudy
containers, never in this shell.

Start a project from a git repository (one folder per repository):
  mkdir -p ~/projects/NAME && cd ~/projects/NAME
  claudy pubkey                                     # add this key as a deploy key on that repository
  claudy git clone git@github.com:OWNER/REPO.git .  # note the final "."
  claudy                                            # Claude Code in the project

Other commands: claudy bash, claudy jupyter, claudy vscode, claudy --ports 8080 <command>

Containers for your project run inside claudy, not on this host:
  claudy bash -c 'podman run --rm docker.io/library/hello-world'
  CLAUDY_NESTED=1 claudy        # faster storage, images kept per project

Don't put SSH keys or tokens in this distro, and never give Claude the sudo password.
HELP
    printf 'Files from Windows: \\\\wsl.localhost\\%s\\home\\%s\\projects\n' "${WSL_DISTRO_NAME:-<distro>}" "$USER"
    printf 'Show this again: claudy-help    Full guide: ~/claudy/README.md\n'
}
_claudy_host_welcome=${XDG_CACHE_HOME:-$HOME/.cache}/claudy/welcome-shown
if [ ! -e "$_claudy_host_welcome" ]; then
    claudy-help
    mkdir -p "${_claudy_host_welcome%/*}" && : > "$_claudy_host_welcome"
fi
EOF
grep -qxF '. /etc/claudy-host.bashrc' /etc/bash.bashrc || printf '%s\n' '. /etc/claudy-host.bashrc' >> /etc/bash.bashrc

# /tmp, /dev/shm and /run/shm (WSL mounts it separately) noexec on every boot (a bind mount keeps /tmp's contents if it is not
# a separate mount). debconf would run package config scripts from /tmp, so apt uses /var/tmp.
cat > /etc/systemd/system/claudy-tmp-noexec.service <<'EOF'
[Unit]
Description=Mount /tmp, /dev/shm and /run/shm noexec (claudy host: no running code from there)
After=local-fs.target tmp.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in /tmp /dev/shm /run/shm; do [ -d "$$d" ] && [ ! -L "$$d" ] || continue; mountpoint -q "$$d" || mount --bind "$$d" "$$d"; mount -o remount,bind,nosuid,nodev,noexec "$$d"; done'

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/claudy-tmp-noexec.service /etc/systemd/system/multi-user.target.wants/claudy-tmp-noexec.service
printf '%s\n' 'APT::ExtractTemplates::TempDir "/var/tmp";' > /etc/apt/apt.conf.d/50claudy-tmp-noexec
systemctl daemon-reload && systemctl start claudy-tmp-noexec.service
```

**If you deliberately give a guard rail up**, know what you lose: every tool you install runs as your user next to the sandbox, outside any container, and is reachable after an escape. Prefer another WSL distro (or machine) for that work; it costs nothing to keep one. If it has to be this distro:

* Remove only the package you need from the `Package:` line of the pin file rather than deleting the file, install it, and when you are done `sudo apt purge --autoremove <pkg>` and put the name back.
* Never reinstall `openssh-client` or add SSH keys or git credentials here (see *Keep Claude away from the distro itself*); that undoes the per-project deploy keys.
* For `/tmp`, `sudo mount -o remount,exec /tmp` lasts until the next restart of the distro; don't disable the service.
* Note what you changed, so you can undo it, or recreate the distro from `new-claudy-distro.ps1` (see *Replacing an existing distro deletes its files*).

### 6. Keep Claude away from the distro itself

Claude may change the *running* container for its work (install a tool, edit `/etc`), but those changes vanish when it exits, and it can't change the image, `claudy` or anything on the host. Anything a project needs permanently, Claude sets up and documents in that project, the way the project already does it (`environment.yml`, `pyproject.toml`, a `Dockerfile`, the README), so it shows up in `git diff` for you to review. This holds only if you keep the roles apart:

* **Claude runs only in the container.** Start it with `claudy`, never by running `claude` directly in the distro's shell. A Claude running in the distro shell would act as your Linux user, with your `sudo` rights and access to `~/claudy`.
* **Never give Claude the `sudo` password.** Don't type it into a Claude prompt or into any command Claude is running, and don't answer a `sudo` password prompt that appears in a session where Claude is working. The distro's `sudo` is for you, in a separate terminal, outside `claudy`.
* **Don't enable passwordless sudo** (no `NOPASSWD` in `/etc/sudoers.d/`).
* **Rebuilds and updates are done by you, outside the container.** If Claude needs another package, a changed `Dockerfile`, a new Miniforge or a rebuilt image, it should tell you what to change. You review the change, then run `git pull`, `podman build ...` or `sudo apt ...` in your own terminal and restart `claudy`. Claude shouldn't be asked to do this for you, and shouldn't be given a way to.
* **Nested containers are Claude's workspace.** Inside the container it can pull images, build its own images and run containers for development work. That inner storage is the per-project `claude-containers-*` volume, separate from the outer image and from your host's Podman images, so it can't modify the `claudy` image. Remove it with `podman volume rm` to start clean.
* **Keep `~/claudy` out of the mounted project folder** and never run `claudy` from inside it (or from its parent directory), because the project folder is writable by Claude, and `claudy`, `Dockerfile` and `entrypoint.sh` are executed with your rights.
* **Don't put credentials for this distro into a project**: no `~/.ssh` keys, tokens or `.env` files holding secrets you wouldn't give to Claude.
* **No SSH keys or git credentials in the distro, and no `ssh` client.** The trim removes `openssh-client` on purpose, and the distro only fetches this repository over HTTPS. Git access for projects belongs to the per-project deploy keys inside `claudy` containers, one key per project and repository. A key, SSH agent, token or credential helper (`~/.git-credentials`) in the distro itself would reach every repository it is allowed on, and would be the first thing an escape from a container finds, which undoes the point of separate keys. Don't reinstall `openssh-client` or add keys there; push and pull projects from inside `claudy`, and maintain this repository (push, pull requests) from your normal environment, not from this distro.
* **Don't use the distro to run or test your applications** (the guard rails in step 5 help you notice). Project code, test suites, dev servers, notebooks and `make` run in the distro shell would run as your user outside the container, with the access the sandbox is meant to keep from them, and would need the toolchains the trim removed. Run them inside `claudy` (`claudy bash`, `claudy --ports ...`, `claudy jupyter`, `claudy vscode`). The distro is only a launcher: Podman, git for this repository, and an editor.

## Updating Claude Code

Claude Code is installed when the image is built. Updates made at runtime are lost with `--rm`, so rebuild periodically:

```bash
cd ~/claudy
podman build --pull --no-cache -t claudy .   # or: make rebuild
```

Your login is kept, as it lives in the `claude-config` volume.

## Security notes

See [`SECURITY.md`](SECURITY.md) for the threat model, risks and limitations.

What the container can see:

* `/workspace`: the folder you started it from, read-write.
* `/root/.ssh`: this project's own SSH key volume (see above).
* With `CLAUDY_NESTED=1` only: `/dev/fuse` and `/var/lib/containers` (inner image storage, per project).
* `/claude-config`: Claude Code's credentials, settings, memory and session history. Shared across projects by default, so it also holds other projects' transcripts; see *Shared or per-project Claude config* for when to give a project its own (`CLAUDY_CONFIG=claude-config-<project>`).

What it cannot see: the rest of the WSL filesystem, the Windows drives, your personal SSH keys and your git credentials, and other projects' SSH keys.

Risks to be aware of (each explained in `SECURITY.md`):

* **It limits mistakes, it doesn't isolate projects from each other** (*Goal and threat model*). Sessions share the Claude config volume by default, and an escape from any container lands as your user.
* **On WSL2 the dedicated distro is not a virtual machine**: root in the distro can reach your Windows files, so nothing from a container may get there, and never type the `sudo` password where Claude or code it ran could see it (*WSL2 is not a virtual machine boundary to Windows*).
* **What you run or open outside the container is outside the sandbox**: scripts, hooks and notebooks from the project, its `.conda_env`, and pages from `--ports`, Jupyter or `claudy vscode` in your browser (*The project folder is writable*, *The project conda env*, *Published ports*).
* **The image could be swapped under you**: anything running as your user on the host can replace the `claudy` image, and the next start runs it with your project and login. Rebuild from a reviewed checkout (*The image can be replaced without notice*).
* **Your local network is reachable**: the router, file shares, printers, devices and other computers at home or work, and whatever a VPN on your computer connects to (*Your home or office network*).
* **For stronger isolation, use a virtual machine**, preferably one per project at a cloud provider, with no cloud permissions and no open ports (*Stronger isolation: a virtual machine, preferably in the cloud*).
* **Instructions are not enforcement**: plugins, skills, hooks and tool servers you install, files and web pages Claude reads, and its own possibly outdated knowledge can steer it past any instruction; connectors to your other accounts are outside the container entirely (*Plugins, skills, tool servers and connectors*, *What Claude knows or finds online*).
* **VS Code in the browser** runs extensions with Claude's access and makes it easy to bring credentials, sync or downloads across the boundary (*VS Code in the browser*).
* **Deploy keys reach beyond the container**: a write key can push to any branch and start CI (*SSH deploy keys reach beyond the container*).
* **Network access is unrestricted.** Claude, or code it runs, can send anything in `/workspace` to the internet. Do not use this sandbox for data that must not leave the machine, such as Trusted Research Environment data.
* No ports are published by default. `claudy jupyter` (8888), `claudy vscode` (8000) and `--ports` bind to `127.0.0.1` only.
* Avoid VS Code Dev Containers for this setup: by default they forward your SSH agent and git credentials into the container.
* To log out everywhere: `podman volume rm claude-config`.

## Troubleshooting

* **`claude: command not found` / conda errors on start**: check the entrypoint output; a failed `conda env create` stops the container. Delete `.conda_env/` to start from scratch.
* **The organisation is not offered at login**: check on claude.ai that the browser is signed in with the email your organisation's admin invited, and that the invitation has been accepted.
* **`jupyter: not found`**: add `notebook` to the project's `environment.yml` (see *Jupyter Notebook*).
* **Port already in use** (`address already in use` from podman): another `claudy jupyter`, `claudy vscode` or `claudy --ports` session holds it; stop that one or pick another port.
