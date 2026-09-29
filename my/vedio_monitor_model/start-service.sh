#!/bin/bash
set -euo pipefail

repo_root="${SYMPHONY_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
workflow="$repo_root/my/vedio_monitor_model/WORKFLOW.md"
logs_root="${SYMPHONY_LOGS_ROOT:-$HOME/code/vedio-monitor-model-symphony-logs}"
port="${SYMPHONY_PORT:-4102}"
escript="${MISE_ESCRIPT:-$HOME/.local/share/mise/installs/erlang/28.5/bin/escript}"

export PATH="$HOME/.npm-global/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
env_file="${SYMPHONY_GITHUB_TOKEN_FILE:-$HOME/.config/symphony/vedio-monitor-model/GITHUB_TOKEN}"
model_env_file="${SYMPHONY_MODEL_ENV_FILE:-$HOME/.config/symphony/vedio-monitor-model/environment}"

if [[ -r "$env_file" ]]; then
  export GITHUB_TOKEN="$(cat "$env_file")"
else
  export GITHUB_TOKEN="$(gh auth token)"
fi

if [[ -r "$model_env_file" ]]; then
  source "$model_env_file"
fi

: "${ARK_API_KEY:?Set ARK_API_KEY in $model_env_file}"

exec "$escript" "$repo_root/elixir/bin/symphony" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root" \
  --port "$port" \
  "$workflow"
