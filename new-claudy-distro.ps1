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
    throw "A WSL distro named '$Name' already exists. Choose another -Name, or remove it with 'wsl --unregister $Name' (this deletes its files)."
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

apt-get update
apt-get -y full-upgrade
apt-get install -y --no-install-recommends \
    ca-certificates git vim nano less sudo unattended-upgrades \
    podman uidmap passt slirp4netns fuse-overlayfs crun conmon netavark aardvark-dns catatonit nftables
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

keep=(apt sudo sudo-rs systemd systemd-sysv systemd-resolved init
      dbus dbus-user-session libpam-systemd wsl-setup ca-certificates locales tzdata
      unattended-upgrades less vim vim-tiny nano git iproute2 procps nftables
      podman uidmap passt slirp4netns fuse-overlayfs crun conmon netavark aardvark-dns catatonit)

remove=(
  # GUI and desktop tools
  code alacritty x11-utils x11-xserver-utils xauth dbus-x11 ibus-gtk3 xdg-utils
  xdg-user-dirs mupdf-tools libnotify-bin
  # documents
  pandoc texlive-base texlive-binaries texlive-fonts-recommended texlive-latex-base
  texlive-latex-extra texlive-latex-recommended texlive-luatex texlive-pictures
  texlive-plain-generic lmodern tipa dvisvgm
  # toolchains: these belong in the container
  build-essential gcc g++ make dpkg-dev nodejs npm eslint webpack terser gyp
  handlebars wabt ruby rake default-jre default-jre-headless openjdk-25-jre
  openjdk-25-jre-headless tcl tk buildah criu
  # remote management, telemetry, cloud and Windows integration agents
  snapd landscape-client landscape-common ubuntu-pro-client ubuntu-pro-client-l10n
  wsl-pro-service ubuntu-insights cloud-init cloud-init-base cloud-guest-utils
  apport apport-core-dump-handler apport-symptoms python3-apport packagekit
  software-properties-common update-manager-core ubuntu-release-upgrader-core
  update-motd motd-news-config show-motd command-not-found pastebinit
  # interactive extras and services the sandbox host doesn't need
  byobu screen tmux htop run-one chrony rsyslog openssh-client rsync lsof lshw ethtool
)

installed() { dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' "$@" 2>/dev/null | awk '$1 == "ii" { print $2 }'; }

# Protect what must stay, so removing a metapackage can't take it along
mapfile -t keep_installed < <(installed "${keep[@]}")
apt-mark manual "${keep_installed[@]}" >/dev/null

mapfile -t to_remove < <(installed "${remove[@]}")
plan=$(apt-get -s purge --autoremove "${to_remove[@]}" | awk '$1 == "Purg" || $1 == "Remv" { sub(/:.*/, "", $2); print $2 }' | sort -u)
bad=$(comm -12 <(printf '%s\n' "$plan") <(printf '%s\n' "${keep[@]}" | sort -u))
if [ -n "$bad" ]; then
    echo "Refusing to trim: it would remove required packages:" $bad >&2
    exit 1
fi
if [ -n "$plan" ]; then
    echo "Removing $(printf '%s\n' "$plan" | wc -l) packages:" $plan
    apt-get -y purge --autoremove "${to_remove[@]}"
fi

# Leftover configuration of removed packages
mapfile -t leftover < <(dpkg -l | awk '$1 == "rc" { print $2 }')
if [ ${#leftover[@]} -gt 0 ]; then apt-get -y purge "${leftover[@]}"; fi

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
rootless=$(podman info --format '{{.Host.Security.Rootless}}')
if [ "$rootless" != true ]; then echo "FAIL: podman is not rootless" >&2; fail=1; fi
[ "$fail" = 0 ] && echo "OK: no Windows drives, no interop, rootless podman, running as $(id -un)"
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
