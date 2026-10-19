#!/bin/zsh
set -euo pipefail

repo_root="${SYMPHONY_REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
workflow="$repo_root/my/vedio_monitor_model/WORKFLOW.md"
logs_root="${SYMPHONY_LOGS_ROOT:-$HOME/code/vedio-monitor-model-symphony-logs}"
port="${SYMPHONY_PORT:-4103}"
escript="${MISE_ESCRIPT:-$HOME/.local/share/mise/installs/erlang/28.5/bin/escript}"

export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
model_env_file="${SYMPHONY_MODEL_ENV_FILE:-$HOME/.config/symphony/vedio-monitor-model/environment}"

source "$HOME/.zshrc"
: "${ORG_GITHUB_TOKEN:?Set ORG_GITHUB_TOKEN in ~/.zshrc}"
export GITHUB_TOKEN="$ORG_GITHUB_TOKEN"
unset ORG_GITHUB_TOKEN SELF_GITHUB_TOKEN GH_TOKEN

if [[ -r "$model_env_file" ]]; then
  source "$model_env_file"
fi

: "${ARK_API_KEY:?Set ARK_API_KEY in $model_env_file}"

exec "$escript" "$repo_root/elixir/bin/symphony" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root" \
  --port "$port" \
  "$workflow"
