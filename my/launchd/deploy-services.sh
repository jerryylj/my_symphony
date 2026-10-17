#!/bin/bash
set -euo pipefail

# Deploy the current repository configuration to the macOS user-service runtime.
#
# This repository is under ~/Documents, which a LaunchAgent cannot read because
# of macOS privacy controls. The user services therefore run a synchronized copy
# from ~/Library/Application Support/Symphony/runtime. Run this script after
# changing either service's WORKFLOW.md, start-service.sh, shared workflow files,
# or elixir/bin/symphony.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
runtime_root="$HOME/Library/Application Support/Symphony/runtime"
agents_root="$HOME/Library/LaunchAgents"
logs_root="$HOME/Library/Logs/Symphony"
secrets_root="$HOME/Library/Application Support/Symphony/secrets"
user_domain="gui/$(id -u)"

if [[ ! -x "$repo_root/elixir/bin/symphony" ]]; then
  echo "Missing executable: $repo_root/elixir/bin/symphony" >&2
  echo "Install or build the Symphony executable before deploying." >&2
  exit 1
fi

install -d "$runtime_root/elixir/bin" \
  "$runtime_root/my/stock_manage" \
  "$runtime_root/my/vedio_monitor_model" \
  "$runtime_root/my/workflow-libraries" \
  "$agents_root" \
  "$logs_root" \
  "$secrets_root"

# LaunchAgents do not inherit this terminal's credentials. Seed their private
# files on the first deployment, and refresh them when the values are available.
if github_token="$(gh auth token 2>/dev/null)"; then
  printf '%s\n' "$github_token" > "$secrets_root/GITHUB_TOKEN"
elif [[ ! -r "$secrets_root/GITHUB_TOKEN" ]]; then
  echo "No GitHub token is available for the LaunchAgents." >&2
  exit 1
fi

if [[ -n "${ARK_API_KEY:-}" ]]; then
  printf 'export ARK_API_KEY=%q\n' "$ARK_API_KEY" > "$secrets_root/environment"
elif [[ ! -r "$secrets_root/environment" ]]; then
  echo "ARK_API_KEY is not set and no saved LaunchAgent environment exists." >&2
  exit 1
fi

chmod 600 "$secrets_root/GITHUB_TOKEN" "$secrets_root/environment"

install -m 755 "$repo_root/elixir/bin/symphony" "$runtime_root/elixir/bin/symphony"
install -m 755 "$repo_root/my/stock_manage/start-service.sh" \
  "$runtime_root/my/stock_manage/start-service.sh"
install -m 644 "$repo_root/my/stock_manage/WORKFLOW.md" \
  "$runtime_root/my/stock_manage/WORKFLOW.md"
install -m 755 "$repo_root/my/vedio_monitor_model/start-service.sh" \
  "$runtime_root/my/vedio_monitor_model/start-service.sh"
install -m 644 "$repo_root/my/vedio_monitor_model/WORKFLOW.md" \
  "$runtime_root/my/vedio_monitor_model/WORKFLOW.md"
install -m 644 "$repo_root/my/workflow-libraries/github-serial.yml" \
  "$runtime_root/my/workflow-libraries/github-serial.yml"
install -m 644 "$repo_root/my/workflow-libraries/github-serial.md" \
  "$runtime_root/my/workflow-libraries/github-serial.md"

for label in com.symphony.stock-manage com.symphony.vedio-monitor-model; do
  plist="$repo_root/my/launchd/$label.plist"
  destination="$agents_root/$label.plist"

  plutil -lint "$plist" >/dev/null
  launchctl bootout "$user_domain/$label" 2>/dev/null || true
  install -m 644 "$plist" "$destination"
  launchctl bootstrap "$user_domain" "$destination"
  launchctl kickstart -k "$user_domain/$label"
done

echo "Symphony services deployed and started."
