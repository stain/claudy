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

# Commit identity: the image's placeholder (Claude Sandbox) labels Claude's commits only.
# It is removed from the editor's environment, so Source Control commits with git config
# (and git refuses instead of guessing when none is set), and given back to VS Code
# terminals and the Claude Code extension through machine settings, which this rewrites.
# Identities from CLAUDY_GIT_NAME/CLAUDY_GIT_EMAIL stay for everyone, as in plain claudy.
ident_vars=(GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL)
sandbox=()
for v in "${ident_vars[@]}"; do
  case "${!v:-}" in "Claude Sandbox" | claude-sandbox@localhost) sandbox+=("$v") ;; esac
done
sandbox_env=$(for v in "${sandbox[@]}"; do jq -n --arg k "$v" --arg v "${!v}" '{($k): $v}'; done | jq -s 'add // {}')
SETTINGS=$DATA/server/data/Machine/settings.json
mkdir -p "${SETTINGS%/*}"
[ -s "$SETTINGS" ] || echo '{}' > "$SETTINGS"
if jq --argjson env "$sandbox_env" --args '
     .["terminal.integrated.env.linux"] =
       ((.["terminal.integrated.env.linux"] // {}) | with_entries(select(.key | IN($ARGS.positional[]) | not))) + $env
   | .["claudeCode.environmentVariables"] =
       ([(.["claudeCode.environmentVariables"] // [])[] | select(.name | IN($ARGS.positional[]) | not)]
        + ($env | to_entries | map({name: .key, value})))
   ' "${ident_vars[@]}" < "$SETTINGS" > "$SETTINGS.new"; then
  mv "$SETTINGS.new" "$SETTINGS"
  unset "${sandbox[@]}"
  export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=user.useConfigOnly GIT_CONFIG_VALUE_0=true
  claudy-git-identity-notice --editor || true
else
  rm -f "$SETTINGS.new"
  echo "vscode-serve: can't update $SETTINGS (not plain JSON?); Source Control keeps the sandbox identity" >&2
fi

exec "$CLI" --cli-data-dir "$DATA/cli" serve-web \
  --host 0.0.0.0 --port "$PORT" \
  --connection-token-file "$TOKEN_FILE" \
  --accept-server-license-terms \
  --disable-telemetry \
  --server-data-dir "$DATA/server" \
  --default-folder "$PWD"
