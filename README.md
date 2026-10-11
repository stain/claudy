# Claude Code sandbox (Podman on WSL2)

A container image for running Claude Code, Snakemake and Jupyter where only the current project folder is visible to the container. Claude authenticates with your Claude Team subscription login; no API key is needed.

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

## First-time setup

### 1. Get the repository and build the image

```bash
git clone https://github.com/stain/claudy.git ~/claudy
cd ~/claudy
podman build -t claudy .
```

The repository is public, so the HTTPS clone needs no credentials (use it rather than `git@github.com:...`, which needs an SSH key). Update later with `git -C ~/claudy pull`, then rebuild the image.

The `Dockerfile` uses a fully qualified base image (`docker.io/library/node:22-slim`), so Podman needs no registry configuration. The build installs git, ssh, jq, zip/unzip, patch, build tools and an editor alongside Claude Code and Miniforge, and takes a few minutes the first time.

### 2. Install the launcher script

Link `claudy` into `~/bin`, so it stays in sync with this repository:

```bash
mkdir -p ~/bin
ln -s ~/claudy/claudy ~/bin/claudy
```

On Ubuntu, `~/.profile` adds `~/bin` to `PATH` if the directory exists at login. If you have just created it, open a new WSL terminal (or run `export PATH="$HOME/bin:$PATH"`) and check with `command -v claudy`.

`claudy` mounts the current directory at `/workspace` and the `claude-config` volume at `/claude-config`, and nothing else. It refuses to run from `/`, `$HOME` or the Windows drive.

Make sure `ANTHROPIC_API_KEY` is not exported in your shell. If it were set, Claude Code would try API-key authentication instead of your Team subscription.

### 3. Start Claude and log in

```bash
cd ~/projects/my-analysis
claudy
```

If the project contains `environment.yml`, the conda environment is created first in `.conda_env/`. This takes a few minutes the first time.

Claude Code then asks for a login method:

1. Choose the **Claude subscription** login (not Claude Console / API).
2. Open the printed URL in your Windows browser, signed in with the account that is a member of BioFAIR.
3. Select the **BioFAIR** Team organisation and click **Authorize**.
4. The browser cannot redirect back into the container, so it shows a code. Paste it at the `Paste code here if prompted` prompt.

Run `/status` in Claude to confirm the account and organisation. If it picked the wrong organisation, run `/login` and choose again.

The credentials are stored in the `claude-config` Podman volume. They survive `--rm`, reboots and image rebuilds, so you only log in once.

## Everyday use

From any project folder:

```bash
claudy                       # Claude Code
claudy bash                  # a shell in the same environment
claudy snakemake --cores 4   # any command
claudy pubkey                # this project's SSH public key
claudy jupyter               # Jupyter on http://localhost:8888 (use the token URL it prints)
```

The project's conda environment (`/workspace/.conda_env/bin`) is on `PATH` for every command, so there is no need for `conda activate`.

## Conda environment

`environment.yml` lives in the project, not in this repository. On each start the entrypoint:

* creates `.conda_env/` if it does not exist;
* runs `conda env update --prune` if `environment.yml` is newer than the environment;
* otherwise does nothing.

The image uses Miniforge (conda-forge). Do not add the Anaconda `defaults` channel: it requires accepting Anaconda's Terms of Service and is subject to its organisational licensing terms. Use:

```yaml
channels:
  - conda-forge
  - bioconda
```

Add `.conda_env/` to the project's `.gitignore`.

## Git and GitLab (SSH)

Your own SSH keys and git credentials are never visible to the container. Instead, each project folder gets **its own SSH key**, stored in a per-project Podman volume (`claude-ssh-<folder>-<hash>`, mounted at `/root/.ssh`). Containers for different projects cannot see each other's keys.

The key is generated on the first start and its public key is printed. To show it again:

```bash
claudy pubkey
```

Add it in GitLab as a **deploy key** for that one repository (*Settings → Repository → Deploy keys*), with *Grant write permissions* only if Claude should push. Do not add it to your user account: a user key would give the container access to every repository you can reach.

Notes:

* The private key is readable by anything running in the container, including Claude. A write-enabled deploy key lets Claude push to that repository, so protect important branches in GitLab.
* The key has no passphrase, and no SSH agent is forwarded.
* Host keys are recorded on first contact (`StrictHostKeyChecking accept-new`) and kept in the same volume. For a self-hosted GitLab this works the same way.
* To revoke: delete the deploy key in GitLab, and `podman volume rm` the volume (`podman volume ls` lists them). Removing it makes the next start generate a new key.
* Commits are authored as `Claude Sandbox <claude-sandbox@localhost>` by default. Override per run:
  `CLAUDY_GIT_NAME="Your Name" CLAUDY_GIT_EMAIL=you@biofair.uk claudy`.
  To change the default, edit the `GIT_*` variables in the `Dockerfile` and rebuild.

## Dedicated WSL distro for nested containers (Windows only)

Normal use needs none of this. It only applies if you want Claude to run containers itself (`CLAUDY_NESTED=1`), which passes `/dev/fuse` into the container and enlarges the kernel attack surface. On WSL2 an escape would land in a distro that can read your Windows drives and start Windows programs as you, so for nested mode use a **separate WSL distro that has neither**.

On a plain Linux host there is no Windows side to protect: skip this section. Nested mode is still opt-in and off by default, and `claudy` only checks the WSL conditions when it detects WSL.

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

Save (Ctrl+O, Enter, Ctrl+X), then restart the distro from PowerShell so the settings take effect:

```powershell
wsl --terminate claude-sandbox
wsl -d claude-sandbox
```

Check that the isolation works inside the distro:

```bash
ls /mnt/c                   # empty or missing
cmd.exe                     # command not found
```

### 3. Install and use

Inside the distro, install the prerequisites (`sudo apt update && sudo apt install -y podman`), then follow *First-time setup* above: it clones this repository from GitHub over HTTPS, builds the image and links `claudy`. That is the only thing the isolated distro fetches from outside, so it needs no keys. For nested mode build the second image and start with the flag:

```bash
podman build --build-arg WITH_PODMAN=1 -t claudy-nested .
cd ~/projects/my-analysis
CLAUDY_NESTED=1 claudy
```

Notes:

* Keep projects on the distro's own filesystem (`~/projects`). Copy files in and out through `\\wsl.localhost\claude-sandbox\home\youruser` in Windows Explorer.
* Without interop the login URL cannot open a browser: copy it from the terminal into your Windows browser by hand (the README's login steps already do this).
* `localhost:8888` for Jupyter is still forwarded to Windows.
* All WSL2 distros share one Linux kernel and VM. A separate distro keeps your Windows files out of reach, but it is not a separate virtual machine. The container can also still reach the network.
* `claudy` and the `Dockerfile` run with your user's rights on the host, so `git pull` only from a source you trust, and read `git diff` of those two files after pulling.
* `claudy` refuses nested mode on WSL while `/mnt/<drive>` or interop is active. `CLAUDY_ALLOW_UNSAFE_NESTED=1` overrides this; don't.

### 4. Keep Claude away from the distro itself

Claude should be able to build and run containers for development work, but never to change its own sandbox. This holds only if you keep the roles apart:

* **Claude runs only in the container.** Start it with `claudy`, never by running `claude` directly in the distro's shell. A Claude running in the distro shell would act as your Linux user, with your `sudo` rights and access to `~/claudy`.
* **Never give Claude the `sudo` password.** Don't type it into a Claude prompt or into any command Claude is running, and don't answer a `sudo` password prompt that appears in a session where Claude is working. The distro's `sudo` is for you, in a separate terminal, outside `claudy`.
* **Don't enable passwordless sudo** (no `NOPASSWD` in `/etc/sudoers.d/`).
* **Rebuilds and updates are done by you, outside the container.** If Claude needs another package, a changed `Dockerfile`, a new Miniforge or a rebuilt image, it should tell you what to change. You review the change, then run `git pull`, `podman build ...` or `sudo apt ...` in your own terminal and restart `claudy`. Claude shouldn't be asked to do this for you, and shouldn't be given a way to.
* **Nested containers are Claude's workspace.** Inside the container it can pull images, build its own images and run containers for development work. That inner storage is the per-project `claude-containers-*` volume, separate from the outer image and from your host's Podman images, so it can't modify `claudy` or `claudy-nested`. Remove it with `podman volume rm` to start clean.
* **Keep `~/claudy` out of the mounted project folder** and never run `claudy` from inside it (or from its parent directory), because the project folder is writable by Claude, and `claudy`, `Dockerfile` and `entrypoint.sh` are executed with your rights.
* **Don't put credentials for this distro into a project**: no `~/.ssh` keys, tokens or `.env` files holding secrets you wouldn't give to Claude.

## Updating Claude Code

Claude Code is installed when the image is built. Updates made at runtime are lost with `--rm`, so rebuild periodically:

```bash
cd ~/claudy
podman build --pull --no-cache -t claudy .
```

Your login is kept, as it lives in the `claude-config` volume.

## Security notes

See [`SECURITY.md`](SECURITY.md) for the threat model, risks and limitations.

What the container can see:

* `/workspace`: the folder you started it from, read-write.
* `/root/.ssh`: this project's own SSH key volume (see above).
* With `CLAUDY_NESTED=1` only: `/dev/fuse` and `/var/lib/containers` (inner image storage, per project).
* `/claude-config`: Claude Code's credentials, settings and session history. This volume is shared across projects, so it also holds transcripts from other projects. For strict separation between projects, run `CLAUDY_CONFIG="claude-config-$(basename "$PWD")" claudy`, at the cost of logging in once per project.

What it cannot see: the rest of the WSL filesystem, the Windows drives, your personal SSH keys and your git credentials, and other projects' SSH keys.

Limits of this isolation:

* **Network access is unrestricted.** Claude, or code it runs, can send anything in `/workspace` to the internet. Do not use this sandbox for data that must not leave the machine, such as Trusted Research Environment data.
* Port 8888 is bound to `127.0.0.1` only, and only by `claudy jupyter`.
* Avoid VS Code Dev Containers for this setup: by default they forward your SSH agent and git credentials into the container.
* To log out everywhere: `podman volume rm claude-config`.

## Troubleshooting

* **`claude: command not found` / conda errors on start**: check the entrypoint output; a failed `conda env create` stops the container. Delete `.conda_env/` to start from scratch.
* **The organisation is not offered at login**: check on claude.ai that the browser is signed in with the email the BioFAIR admin invited, and that the invitation has been accepted.
* **Port 8888 already in use**: another `claudy jupyter` is running; stop it or change the host port in the `claudy` script.
