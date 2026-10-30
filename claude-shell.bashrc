# rcfile for the image's default command: bash --rcfile <this> -i [-s -- claude args].
# Claude runs as a job of this interactive shell instead of as PID 1, which can't be
# stopped from inside its PID namespace, so Ctrl-Z suspends it to this prompt and `fg`
# resumes it. When Claude exits, so does the shell, also after a suspend and `fg`.

# --rcfile replaces both of these. claudy already warned about the placeholder identity
# on the host, so skip the terminal notice here.
claudy-git-identity-notice() { :; }
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc
[ -f ~/.bashrc ] && . ~/.bashrc
unset -f claudy-git-identity-notice

claudy_args=("$@")
set --
# Started from the first prompt: bash runs commands from startup files in its own
# process group, where Ctrl-Z can't stop them.
claudy_prompt_command=${PROMPT_COMMAND:-}
claudy_start() {
  # Absolute path: /workspace/.conda_env/bin is first on PATH, so a `claude` there would win
  /usr/local/bin/claude "${claudy_args[@]}"
  local status=$?
  unset claudy_args
  unset -f claudy_start
  claudy_pid=$(jobs -sp)
  if [ -z "$claudy_pid" ]; then exit "$status"; fi
  # Suspended: exit too once it ends after `fg`, with its status
  PROMPT_COMMAND="claudy_watch${claudy_prompt_command:+; $claudy_prompt_command}"
}
claudy_watch() {
  local status=$?
  jobs -p | grep -qxF "$claudy_pid" || exit "$status"
}
PROMPT_COMMAND=claudy_start
