#!/bin/bash
# VS Code in the browser, served from inside the container (run by `claudy vscode`).
# The VS Code CLI is in the image; on first start it downloads the matching server
# into $DATA, a per-project volume that also keeps installed extensions.
set -euo pipefail

PORT=${1:?usage: vscode-serve <port>}
CLI=/opt/vscode/code
DATA=/root/.vscode-claudy

[ -x "$CLI" ] || { echo "vscode-serve: VS Code CLI not in this image (built with WITH_VSCODE=0?)" >&2; exit 1; }

# New token on every start, kept in a file rather than on a command line
umask 077
TOKEN_FILE=/run/claudy-vscode-token
head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' > "$TOKEN_FILE"

echo "VS Code (open in a separate browser profile): http://localhost:$PORT/?tkn=$(cat "$TOKEN_FILE")" >&2
echo "By using it you accept the VS Code Server license terms: https://aka.ms/vscode-server-license" >&2

exec "$CLI" --cli-data-dir "$DATA/cli" serve-web \
  --host 0.0.0.0 --port "$PORT" \
  --connection-token-file "$TOKEN_FILE" \
  --accept-server-license-terms \
  --disable-telemetry \
  --server-data-dir "$DATA/server" \
  --default-folder "$PWD"
