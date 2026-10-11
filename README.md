# Claude Code sandbox (Podman on WSL2)

A container image for running Claude Code, Snakemake and Jupyter where only the current project folder is visible to the container. Claude authenticates with your Claude Team (BioFAIR) subscription login; no API key is needed.

## Layout

Keep the sandbox definition separate from the projects it runs on, so that Claude can never edit its own container configuration:

```
~/claude-sandbox/          this repository: Dockerfile, entrypoint.sh, claude-box, README.md
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

### 1. Build the image

```bash
cd ~/claude-sandbox
podman build -t claude-sandbox .
```

### 2. Install the launcher script

Link `claude-box` into `~/bin`, so it stays in sync with this repository:

```bash
mkdir -p ~/bin
ln -s ~/claude-sandbox/claude-box ~/bin/claude-box
```

On Ubuntu, `~/.profile` adds `~/bin` to `PATH` if the directory exists at login. If you have just created it, open a new WSL terminal (or run `export PATH="$HOME/bin:$PATH"`) and check with `command -v claude-box`.

`claude-box` mounts the current directory at `/workspace` and the `claude-config` volume at `/claude-config`, and nothing else. It refuses to run from `/`, `$HOME` or the Windows drive.

Make sure `ANTHROPIC_API_KEY` is not exported in your shell. If it were set, Claude Code would try API-key authentication instead of your Team subscription.

### 3. Start Claude and log in

```bash
cd ~/projects/my-analysis
claude-box
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
claude-box                       # Claude Code
claude-box bash                  # a shell in the same environment
claude-box snakemake --cores 4   # any command
claude-box jupyter               # Jupyter on http://localhost:8888 (use the token URL it prints)
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

## Updating Claude Code

Claude Code is installed when the image is built. Updates made at runtime are lost with `--rm`, so rebuild periodically:

```bash
cd ~/claude-sandbox
podman build --pull --no-cache -t claude-sandbox .
```

Your login is kept, as it lives in the `claude-config` volume.

## Security notes

What the container can see:

* `/workspace`: the folder you started it from, read-write.
* `/claude-config`: Claude Code's credentials, settings and session history. This volume is shared across projects, so it also holds transcripts from other projects. For strict separation between projects, run `CLAUDE_BOX_CONFIG="claude-config-$(basename "$PWD")" claude-box`, at the cost of logging in once per project.

What it cannot see: the rest of the WSL filesystem, the Windows drives, your SSH keys and your git credentials.

Limits of this isolation:

* **Network access is unrestricted.** Claude, or code it runs, can send anything in `/workspace` to the internet. Do not use this sandbox for data that must not leave the machine, such as Trusted Research Environment data.
* Port 8888 is bound to `127.0.0.1` only, and only by `claude-box jupyter`.
* Avoid VS Code Dev Containers for this setup: by default they forward your SSH agent and git credentials into the container.
* To log out everywhere: `podman volume rm claude-config`.

## Troubleshooting

* **`claude: command not found` / conda errors on start**: check the entrypoint output; a failed `conda env create` stops the container. Delete `.conda_env/` to start from scratch.
* **The BioFAIR organisation is not offered at login**: check on claude.ai that the browser is signed in with the email the BioFAIR admin invited, and that the invitation has been accepted.
* **Port 8888 already in use**: another `claude-box jupyter` is running; stop it or change the host port in the `claude-box` script.
