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

`claudy` mounts the current directory at `/workspace` and the `claude-config` volume at `/claude-config`, and nothing else. It also runs the container with a seccomp profile that blocks vsock (how WSL2 talks to Windows), derived on each start from Podman's default into `~/.cache/claudy/seccomp.json`; this needs `python3` on the host. It refuses to run from `/`, `$HOME` or the Windows drive.

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

## Everyday use

From any project folder:

```bash
claudy                       # Claude Code
claudy bash                  # a shell in the same environment
claudy snakemake --cores 4   # any command
claudy pubkey                # this project's SSH public key
claudy jupyter               # Jupyter Notebook on http://localhost:8888 (needs notebook in environment.yml, see below)
claudy --ports 8080,5173     # Claude Code, with these ports reachable on http://localhost:<port> (see below)
```

The project's conda environment (`/workspace/.conda_env/bin`) is on `PATH` for every command, so there is no need for `conda activate`. The entrypoint and interactive shells (via `/etc/bash.bashrc`) also activate it when it exists, and `conda activate` works in those shells.

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
* Ports are fixed when the container starts. To add one, exit and restart with it; `claudy --ports 8080 claude --continue` resumes the last conversation. Claude knows this and asks you to restart when it needs a port, explaining why. Anything not saved in the project (temporary installs, background processes) is lost on restart.
* Inside the container, `CLAUDY_PORTS` lists the published ports.
* While published, the port is reachable by any program on your machine, including web pages in your browser and, on WSL2, the Windows side. Dev servers rarely have authentication, so publish ports only for the session that needs them. See `SECURITY.md`.

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

Notebooks are saved in the project folder. The Jupyter server runs with the same isolation as Claude (only the project folder, its own SSH key), and anyone with the token URL can run code in the container. Without `notebook` in the environment, `claudy jupyter` fails with `jupyter: not found`.

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
* Commits are authored as `Claude Sandbox <claude-sandbox@localhost>` by default. Override per run:
  `CLAUDY_GIT_NAME="Your Name" CLAUDY_GIT_EMAIL=you@example.org claudy`.
  To change the default, edit the `GIT_*` variables in the `Dockerfile` and rebuild.

## Dedicated WSL distro for nested containers (Windows only)

Normal use doesn't strictly need this. Podman inside the container works without it, but uses user namespaces heavily (see `SECURITY.md`, *Nested containers*), so a dedicated distro is recommended if Claude will run containers, and required for `CLAUDY_NESTED=1`, which also passes `/dev/fuse` into the container and enlarges the kernel attack surface further. On WSL2 an escape would land in a distro that can read your Windows drives and start Windows programs as you, so for nested mode use a **separate WSL distro that has neither**.

On a plain Linux host there is no Windows side to protect: skip this section. Nested mode is still opt-in and off by default, and `claudy` only checks the WSL conditions when it detects WSL.

### Automated: `new-claudy-distro.ps1`

`new-claudy-distro.ps1` does steps 1 to 5 below, plus the first-time setup, in one go from Windows. It installs the distro, creates your user (asking for its password), writes `/etc/wsl.conf`, installs Podman, git and vim, removes the packages listed in step 4, restarts the distro, checks that the Windows drives and interop are gone, then clones this repository over HTTPS, builds the image and links `~/bin/claudy`. The Linux part is plain bash embedded in the script and piped into `wsl.exe`; read it before running.

Download it from GitHub (it is a single file), read it, then run it from PowerShell:

```powershell
Invoke-WebRequest https://raw.githubusercontent.com/stain/claudy/main/new-claudy-distro.ps1 -OutFile new-claudy-distro.ps1
notepad new-claudy-distro.ps1
powershell -ExecutionPolicy Bypass -File .\new-claudy-distro.ps1 -User yourname
```

**Warning:** the script runs as you on Windows and as root inside the new distro, and `-ExecutionPolicy Bypass` skips the only check Windows would do, so reading it is the check. Only take it from this repository on GitHub, over HTTPS as above, not from a fork, a mirror, a link someone sent you, or a copy in a WSL folder or project (`\\wsl.localhost\...`) that Claude or a container could have edited. To run exactly the version you reviewed, replace `main` in the URL with a commit hash from the GitHub history.

Options: `-Name` (default `claude-sandbox`), `-Distro` (default `Ubuntu-26.04`), `-Location` (folder for the virtual disk), `-SkipTrim`, `-SkipBuild`. It refuses to touch an existing distro of the same name. Afterwards, back up the result (`wsl --export claude-sandbox claude-sandbox.tar`) and continue with *Keep Claude away from the distro itself* below. The manual steps follow.

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

Save (Ctrl+O, Enter, Ctrl+X). Even with interop disabled, WSL registers the handler that passes `.exe` files to Windows, and it also fires inside containers. Remove it on every boot:

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

Inside the distro, install the prerequisites (`sudo apt update && sudo apt install -y podman`), then follow *First-time setup* above: it clones this repository from GitHub over HTTPS, builds the image and links `claudy`. That is the only thing the isolated distro fetches from outside, so it needs no keys. The image includes Podman by default (build arg `WITH_PODMAN=1`, `0` leaves it out), preconfigured for nested use (subuid/subgid range, host network). Podman works without `/dev/fuse` using the `vfs` storage driver; the entrypoint switches to `overlay` on `fuse-overlayfs` when `/dev/fuse` is present, i.e. with `CLAUDY_NESTED=1`. Nested mode uses the same image; start it with the flag:

```bash
cd ~/projects/my-analysis
CLAUDY_NESTED=1 claudy
```

Notes:

* Keep projects on the distro's own filesystem (`~/projects`). Copy files in and out through `\\wsl.localhost\claude-sandbox\home\youruser` in Windows Explorer.
* Without interop the login URL cannot open a browser: copy it from the terminal into your Windows browser by hand (the README's login steps already do this).
* `localhost:8888` for Jupyter is still forwarded to Windows.
* All WSL2 distros share one Linux kernel and VM. A separate distro keeps your Windows files out of reach of your user, but it is not a separate virtual machine: root in the distro can still mount them (`mount -t drvfs C: /mnt/c`), so the protection depends on nothing reaching root there (see `SECURITY.md`, *WSL2 is not a virtual machine boundary to Windows*). The container can also still reach the network.
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
   # cloud-init, ubuntu-insights, chrony, ethtool, gpg, dbus-x11, xdg-user-dirs and python3-*
   # (wsl-setup or the keep list need them), and Essential/required packages such as
   # coreutils, rust-coreutils or gcc-*-base.
   extra=(
     # remote management, telemetry and Windows integration agents
     snapd landscape-client landscape-common ubuntu-pro-client wsl-pro-service
     apport apport-core-dump-handler software-properties-common ubuntu-release-upgrader-core
     motd-news-config show-motd command-not-found python3-wadllib
     # toolchains and extras the sandbox host doesn't need (the container has its own)
     build-essential xauth byobu screen rsyslog openssh-client rsync wget bc eatmydata
   )
   mapfile -t remove < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "${meta[@]}" "${extra[@]}" 2>/dev/null | awk '$1 == "ii" { print $2 }')
   sudo apt-get -s purge --autoremove "${remove[@]}" | grep -E '^(Purg|Remv)' | less
   sudo apt-get purge --autoremove "${remove[@]}"
   sudo apt autoremove --purge                 # anything else left unused
   sudo apt purge '~c'                         # leftover config of removed packages
   ```

   Don't try to remove what is left by force: `cloud-init`, `ubuntu-insights`, `chrony`, `ethtool`, `gpg`, `dbus-x11`, `xdg-user-dirs` and the `python3-*` packages stay because `wsl-setup` or the packages from step 3 depend on them, and Essential packages (`coreutils`, `rust-coreutils`, `gcc-*-base` and other libraries) are part of the base system. Removing them takes `wsl-setup` along, which WSL needs.

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

* **apt refuses development tools and SSH.** `/etc/apt/preferences.d/claudy-no-dev-tools.pref` pins `openssh-client`, compilers, `make`, Node.js, `pip`/`venv`, Java, Go, Rust, Ruby, Docker and friends to priority -1, so `sudo apt install nodejs` reports *no installation candidate*. Python itself stays: `wsl-setup`, netplan and `claudy` (to build its seccomp profile) need it.
* **The shell reminds you where you are.** Interactive shells show a red `[claudy host]` prompt marker, print a warning when you `cd` into a project under `~/projects`, and answer a missing command with a hint to run it through `claudy` instead.
* **`/tmp` and `/dev/shm` are mounted `noexec`** at every boot (`claudy-tmp-noexec.service`), so a binary downloaded or unpacked there can't be started. apt is told to use `/var/tmp` for package configuration scripts, which would otherwise fail. `~/projects` is deliberately *not* `noexec`: the container's `/workspace` is a bind mount of it and would inherit the flag, breaking every script and conda program inside `claudy`.

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
EOF
grep -qxF '. /etc/claudy-host.bashrc' /etc/bash.bashrc || printf '%s\n' '. /etc/claudy-host.bashrc' >> /etc/bash.bashrc

# /tmp and /dev/shm noexec on every boot (a bind mount keeps /tmp's contents if it is not
# a separate mount). debconf would run package config scripts from /tmp, so apt uses /var/tmp.
cat > /etc/systemd/system/claudy-tmp-noexec.service <<'EOF'
[Unit]
Description=Mount /tmp and /dev/shm noexec (claudy host: no running code from there)
After=local-fs.target tmp.mount

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'for d in /tmp /dev/shm; do mountpoint -q "$$d" || mount --bind "$$d" "$$d"; mount -o remount,bind,nosuid,nodev,noexec "$$d"; done'

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
* **Don't use the distro to run or test your applications** (the guard rails in step 5 help you notice). Project code, test suites, dev servers, notebooks and `make` run in the distro shell would run as your user outside the container, with the access the sandbox is meant to keep from them, and would need the toolchains the trim removed. Run them inside `claudy` (`claudy bash`, `claudy --ports ...`, `claudy jupyter`). The distro is only a launcher: Podman, git for this repository, and an editor.

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
* No ports are published by default. `claudy jupyter` (8888) and `--ports` bind to `127.0.0.1` only.
* Avoid VS Code Dev Containers for this setup: by default they forward your SSH agent and git credentials into the container.
* To log out everywhere: `podman volume rm claude-config`.

## Troubleshooting

* **`claude: command not found` / conda errors on start**: check the entrypoint output; a failed `conda env create` stops the container. Delete `.conda_env/` to start from scratch.
* **The organisation is not offered at login**: check on claude.ai that the browser is signed in with the email your organisation's admin invited, and that the invitation has been accepted.
* **`jupyter: not found`**: add `notebook` to the project's `environment.yml` (see *Jupyter Notebook*).
* **Port already in use** (`address already in use` from podman): another `claudy jupyter` or `claudy --ports` session holds it; stop that one or pick another port.
