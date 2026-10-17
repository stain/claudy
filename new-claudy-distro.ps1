<#
.SYNOPSIS
    Create a dedicated, trimmed WSL distro for claudy (README: "Dedicated WSL distro").

.DESCRIPTION
    Runs on Windows. Installs a new Ubuntu WSL distro under its own name, creates your Linux
    user, writes /etc/wsl.conf (systemd on, no Windows drives, no interop), installs Podman
    and git, removes packages the sandbox host doesn't need, checks the isolation, then
    clones claudy over HTTPS, builds the image and links ~/bin/claudy.

    Everything inside the distro is done by bash scripts embedded below and piped into
    wsl.exe, so the distro never needs access to Windows files. Read them before running.
    The package lists match the README ("Trim the distro"); keep both in sync.

.PARAMETER User
    Linux username to create (lowercase). You are asked for its password; sudo needs it.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\new-claudy-distro.ps1 -User alice

.EXAMPLE
    .\new-claudy-distro.ps1 -User alice -Name claude-sandbox -Location D:\wsl\claude-sandbox
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[a-z_][a-z0-9_-]{0,31}$')]
    [string]$User,

    [string]$Name = 'claude-sandbox',

    [string]$Distro = 'Ubuntu-26.04',

    # Folder for the distro's virtual disk; default is chosen by WSL
    [string]$Location,

    [ValidatePattern("^https://[^\s']+$")]
    [string]$RepoUrl = 'https://github.com/stain/claudy.git',

    # Skip removing packages (not recommended)
    [switch]$SkipTrim,

    # Skip cloning claudy and building the image
    [switch]$SkipBuild
)

$ErrorActionPreference = 'Stop'
$env:WSL_UTF8 = '1'                                         # wsl.exe prints UTF-8, not UTF-16
$OutputEncoding = New-Object System.Text.UTF8Encoding $false  # text piped to wsl.exe

function Invoke-Wsl {
    & wsl.exe @args
    if ($LASTEXITCODE -ne 0) { throw "wsl.exe $($args -join ' ') failed (exit code $LASTEXITCODE)" }
}

# Pipe a bash script into the distro and run it as $As
function Invoke-InDistro([string]$As, [string]$Title, [string]$Script) {
    Write-Host "==> $Title" -ForegroundColor Cyan
    # Windows PowerShell ends piped text with CRLF; the final 'exit' keeps bash from running a stray CR line
    (($Script -replace "`r", '') + "`nexit 0`n") | & wsl.exe -d $Name -u $As -- bash -s
    if ($LASTEXITCODE -ne 0) { throw "$Title failed (exit code $LASTEXITCODE)" }
}

# --- Checks ---------------------------------------------------------------------------

$versionText = (& wsl.exe --version 2>$null) -join "`n"
if ($versionText -match '(\d+)\.(\d+)\.(\d+)') {
    $wslVersion = [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])"
    if ($wslVersion -lt [version]'2.4.4') {
        throw "WSL $wslVersion is too old for 'wsl --install --name' (needs 2.4.4). Run 'wsl --update' first."
    }
} else {
    Write-Warning "Could not read the WSL version; continuing. Run 'wsl --update' if the install fails."
}

$existing = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($existing -contains $Name) {
    throw "A WSL distro named '$Name' already exists. Choose another -Name, or remove it with 'wsl --unregister $Name' (this deletes everything in it, including projects, the Claude login and SSH key volumes; see the README)."
}

# --- Install --------------------------------------------------------------------------

Write-Host "==> Installing $Distro as '$Name'" -ForegroundColor Cyan
$installArgs = @('--install', '-d', $Distro, '--name', $Name, '--no-launch')
if ($Location) { $installArgs += @('--location', $Location) }
Invoke-Wsl @installArgs

$existing = @(& wsl.exe --list --quiet 2>$null | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($existing -notcontains $Name) {
    throw "'$Name' is not registered after installing. Start it once with 'wsl -d $Name', exit, and run this script again with a new -Name, or follow the README by hand."
}

# --- Base setup (root) ----------------------------------------------------------------

$base = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
user='__USER__'

# UID 1000 is what Ubuntu's first-start setup expects; it then skips creating a user
if ! id "$user" >/dev/null 2>&1; then
    if getent passwd 1000 >/dev/null; then
        useradd -m -s /bin/bash -G sudo "$user"
    else
        useradd -m -s /bin/bash -G sudo -u 1000 "$user"
    fi
fi
usermod -aG sudo "$user"

cat > /etc/wsl.conf <<EOF
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

[user]
default = $user
EOF

# With interop disabled, WSL still registers the WSLInterop binfmt handler, and it also fires
# for .exe files started inside containers. Remove it on every boot.
cat > /etc/systemd/system/wsl-remove-interop.service <<'EOF'
[Unit]
Description=Remove the WSL interop binfmt handler (interop is disabled in /etc/wsl.conf)
After=systemd-binfmt.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for f in /proc/sys/fs/binfmt_misc/WSLInterop /proc/sys/fs/binfmt_misc/WSLInterop-late; do if [ -e "$$f" ]; then echo -1 > "$$f"; fi; done'

[Install]
WantedBy=multi-user.target
EOF
mkdir -p /etc/systemd/system/multi-user.target.wants
ln -sfn /etc/systemd/system/wsl-remove-interop.service /etc/systemd/system/multi-user.target.wants/wsl-remove-interop.service

apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
    ca-certificates git vim nano less sudo unattended-upgrades \
    podman uidmap passt slirp4netns fuse-overlayfs crun conmon netavark aardvark-dns catatonit nftables

# --- Guard rails: this distro only launches claudy; code runs in containers ---

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
'@ -replace '__USER__', $User
Invoke-InDistro root 'Creating user, writing /etc/wsl.conf, installing Podman and git' $base

Write-Host "==> Set the Linux password for '$User' (needed for sudo; unrelated to Windows)" -ForegroundColor Cyan
for ($i = 1; $i -le 3; $i++) {
    & wsl.exe -d $Name -u root -- passwd $User
    if ($LASTEXITCODE -eq 0) { break }
    if ($i -eq 3) { throw "Setting the password failed. Run 'wsl -d $Name -u root -- passwd $User' yourself, then continue with the README." }
}

# --- Trim (root) ----------------------------------------------------------------------

$trim = @'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# stdin is this script (bash -s), so nothing below may read from it
apt_get() { apt-get -y "$@" </dev/null; }

keep=(apt sudo sudo-rs systemd systemd-sysv systemd-resolved init
      dbus dbus-user-session libpam-systemd wsl-setup ca-certificates locales tzdata
      unattended-upgrades less vim vim-tiny nano git iproute2 procps nftables
      podman uidmap passt slirp4netns fuse-overlayfs crun conmon netavark aardvark-dns catatonit)

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

installed() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null | awk '$1 == "ii" { print $2 }'; }
# Packages an apt-get command would remove (simulated)
removes() { apt-get -s "$@" </dev/null | awk '$1 == "Purg" || $1 == "Remv" { sub(/:.*/, "", $2); print $2 }' | sort -u; }

# Mark what must stay as manually installed, so neither a metapackage removal nor autoremove takes it
mapfile -t keep_installed < <(installed "${keep[@]}")
apt-mark manual "${keep_installed[@]}" >/dev/null

# Never removed: the keep list and everything Essential or Priority: required
protected=$({ printf '%s\n' "${keep[@]}"
              dpkg-query -W -f='${Package} ${Essential} ${Priority}\n' | awk '$2 == "yes" || $3 == "required" { print $1 }'
            } | sort -u)

# Skip a package whose removal would take a protected one along, instead of failing
to_remove=()
while read -r pkg; do
    hits=$(comm -12 <(removes remove "$pkg") <(printf '%s\n' "$protected"))
    if [ -n "$hits" ]; then
        echo "Keeping $pkg: removing it would also remove" $hits
    else
        to_remove+=("$pkg")
    fi
done < <(installed "${meta[@]}" "${extra[@]}")

# Check the combined plan, including autoremove, before removing anything
if [ ${#to_remove[@]} -gt 0 ]; then
    plan=$(removes purge --autoremove "${to_remove[@]}")
    bad=$(comm -12 <(printf '%s\n' "$plan") <(printf '%s\n' "$protected"))
    if [ -n "$bad" ]; then
        echo "Refusing to trim: it would remove required packages:" $bad >&2
        exit 1
    fi
    echo "Removing $(printf '%s\n' "$plan" | grep -c .) packages:" $plan
    apt_get purge --autoremove "${to_remove[@]}"
fi

# Anything else left unused, and configuration of removed packages
apt_get autoremove --purge
mapfile -t leftover < <(dpkg -l | awk '$1 == "rc" { print $2 }')
if [ ${#leftover[@]} -gt 0 ]; then apt_get purge "${leftover[@]}"; fi

echo "$(dpkg-query -W -f='${db:Status-Abbrev}\n' | grep -c '^ii') packages installed"
'@
if (-not $SkipTrim) {
    Invoke-InDistro root 'Removing packages the sandbox host does not need' $trim
}

# --- Restart and check isolation ------------------------------------------------------

Write-Host "==> Restarting '$Name' so /etc/wsl.conf takes effect" -ForegroundColor Cyan
Invoke-Wsl --terminate $Name

$check = @'
set -euo pipefail
fail=0
if grep -qE ' /mnt/[a-z] (9p|drvfs) ' /proc/mounts; then echo "FAIL: Windows drives are still mounted" >&2; fail=1; fi
if [ -e /proc/sys/fs/binfmt_misc/WSLInterop ] || [ -e /proc/sys/fs/binfmt_misc/WSLInterop-late ]; then
    echo "FAIL: Windows interop is still enabled" >&2; fail=1
fi
if [ "$(ps -p 1 -o comm=)" != systemd ]; then echo "WARNING: systemd is not running as PID 1" >&2; fi
for d in /tmp /dev/shm; do
    findmnt -no OPTIONS "$d" | grep -qw noexec || { echo "FAIL: $d is not mounted noexec" >&2; fail=1; }
done
rootless=$(podman info --format '{{.Host.Security.Rootless}}')
if [ "$rootless" != true ]; then echo "FAIL: podman is not rootless" >&2; fail=1; fi
[ "$fail" = 0 ] && echo "OK: no Windows drives, no interop, /tmp and /dev/shm noexec, rootless podman, running as $(id -un)"
exit "$fail"
'@
Invoke-InDistro $User 'Checking isolation' $check

# --- Clone and build (user) -----------------------------------------------------------

$build = @'
set -euo pipefail
cd ~
[ -d claudy/.git ] || git clone '__REPO__' claudy
cd claudy
podman build -t claudy .
mkdir -p ~/bin ~/projects
ln -sfn ~/claudy/claudy ~/bin/claudy
'@ -replace '__REPO__', $RepoUrl
if (-not $SkipBuild) {
    Invoke-InDistro $User 'Cloning claudy and building the image (takes a few minutes)' $build
}

Write-Host ''
Write-Host "Done. '$Name' is ready." -ForegroundColor Green
Write-Host "  Back it up now:  wsl --export $Name $Name.tar"
Write-Host "  Start it:        wsl -d $Name"
Write-Host "  Then:            mkdir -p ~/projects/my-analysis && cd ~/projects/my-analysis && claudy"
Write-Host "  Projects are in \\wsl.localhost\$Name\home\$User\projects (Windows Explorer)."
Write-Host "  For Podman inside with /dev/fuse:  CLAUDY_NESTED=1 claudy"
