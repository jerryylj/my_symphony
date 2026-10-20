#!/bin/bash
set -euo pipefail

repo_root="${SYMPHONY_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
workflow="$repo_root/my/stock_manage/WORKFLOW.md"
logs_root="${SYMPHONY_LOGS_ROOT:-$HOME/code/stock-manage-symphony-logs}"
port="${SYMPHONY_PORT:-4102}"
escript="${MISE_ESCRIPT:-$HOME/.local/share/mise/installs/erlang/28.5/bin/escript}"
symphony_bin="${SYMPHONY_EXECUTABLE:-$repo_root/elixir/bin/symphony}"

export PATH="$HOME/.npm-global/bin:/opt/homebrew/opt/node@24/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
env_file="${SYMPHONY_GITHUB_TOKEN_FILE:-$HOME/.config/symphony/stock-manage/GITHUB_TOKEN}"
model_env_file="${SYMPHONY_MODEL_ENV_FILE:-$HOME/.config/symphony/stock-manage/environment}"

if [[ -r "$env_file" ]]; then
  export GITHUB_TOKEN="$(cat "$env_file")"
else
  export GITHUB_TOKEN="$(gh auth token)"
fi

if [[ -r "$model_env_file" ]]; then
  source "$model_env_file"
fi

: "${ARK_API_KEY:?Set ARK_API_KEY in $model_env_file}"

if [[ -x "$symphony_bin" ]]; then
  exec "$symphony_bin" \
    --i-understand-that-this-will-be-running-without-the-usual-guardrails \
    --logs-root "$logs_root" \
    --port "$port" \
    "$workflow"
fi

exec "$escript" "$symphony_bin" \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails \
  --logs-root "$logs_root" \
  --port "$port" \
  "$workflow"
