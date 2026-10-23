#!/bin/bash
# Says on stderr which identity commits get. Run by /etc/bash.bashrc in interactive
# terminals (claudy bash, VS Code), where it warns while the image's placeholder
# (Claude Sandbox <claude-sandbox@localhost>) is in use: commits made there get no warning
# from Claude. Run by vscode-serve with --editor after it has removed the placeholder from
# the editor's environment, to say what VS Code's Source Control commits as.
set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0
author=$(git var GIT_AUTHOR_IDENT 2>/dev/null | sed 's/>.*/>/')
committer=$(git var GIT_COMMITTER_IDENT 2>/dev/null | sed 's/>.*/>/')

if [ "${1:-}" = --editor ]; then
  if [ -z "$author" ] || [ -z "$committer" ]; then
    echo "claudy: VS Code's Source Control has no commit identity. Set yours in the project:" >&2
    echo "        git config user.name \"Your Name\"; git config user.email you@example.org" >&2
  else
    echo "claudy: VS Code's Source Control commits as $author (committer $committer)" >&2
  fi
  exit 0
fi

case "$author $committer" in
  *"Claude Sandbox"* | *claude-sandbox@localhost*) ;;
  *) exit 0 ;;
esac

if [ -n "${CLAUDY_VSCODE_PORT:-}" ]; then
  echo "claudy: commits from this terminal, Claude's included, use the sandbox identity $author;" >&2
  echo "        VS Code's Source Control uses your git config instead." >&2
else
  echo "claudy: commits here use the sandbox placeholder identity: author $author, committer $committer" >&2
  echo "        For your own, restart with: CLAUDY_GIT_NAME=\"Your Name\" CLAUDY_GIT_EMAIL=you@example.org claudy bash" >&2
fi
