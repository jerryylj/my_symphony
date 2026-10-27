# Symphony macOS services

`~/Documents` is protected by macOS privacy controls, so user LaunchAgents cannot
run Symphony directly from this repository. The deployed services instead run a
copy from `~/Library/Application Support/Symphony/runtime`.

Two services are registered at login and restarted automatically on failure:

- `com.symphony.stock-manage` on `http://127.0.0.1:4102/`
- `com.symphony.vedio-monitor-model` on `http://127.0.0.1:4103/`

## Redeploy after changes

After changing a service workflow, service launcher, shared workflow library, or
`elixir/bin/symphony`, run:

```bash
./my/launchd/deploy-services.sh
```

The command validates the launch-agent files, copies the current runtime files,
re-registers both LaunchAgents, and starts them again. It intentionally does not
copy any agent workspace: those remain under `/Volumes/cold_storage`.

On its first run, the deployment command stores the current terminal's GitHub
token and `ARK_API_KEY` in `~/Library/Application Support/Symphony/secrets/`
with owner-only permissions. LaunchAgents need this private copy because they do
not inherit a terminal session's credentials. Later deployments retain the saved
credentials if those values are not present in the terminal environment.

LaunchAgent logs are under `~/Library/Logs/Symphony/`.

The service launchers include Homebrew's Node 24 directory
(`/opt/homebrew/opt/node@24/bin`) in `PATH`. The npm-installed `codex` command needs
`node`, and LaunchAgents do not inherit the terminal's shell setup. Without this
directory, Symphony can start its dashboard while agent runs fail immediately
with `env: node: No such file or directory` (exit 127) and enter retry backoff.

## Task workspace Git permissions

The shared GitHub workflow selects `codex.permission_profile: symphony-git`.
Define that profile in `~/.codex/config.toml` for the user running the services:

```toml
[permissions.symphony-git]
extends = ":workspace"

[permissions.symphony-git.filesystem.":workspace_roots"]
".git" = "write"

[permissions.symphony-git.network]
enabled = true
```

This allows branch creation and commits in each issue's original checkout. The
remaining workspace protections, including read-only `.codex` and `.agents`
directories, are inherited. Symphony selects the profile when starting the
Codex thread and does not replace it with a legacy sandbox policy on later turns.
The profile definition alone does not change permissions for other Codex sessions.

To deploy a new executable and shared permission selection while preserving
temporary model overrides in the deployed `WORKFLOW.md` files, build and copy
only those two runtime files, then restart both services:

```bash
(cd elixir && mix build)
runtime="$HOME/Library/Application Support/Symphony/runtime"
install -m 755 elixir/bin/symphony "$runtime/elixir/bin/symphony"
install -m 644 my/workflow-libraries/github-serial.yml \
  "$runtime/my/workflow-libraries/github-serial.yml"
launchctl kickstart -k "gui/$(id -u)/com.symphony.stock-manage"
launchctl kickstart -k "gui/$(id -u)/com.symphony.vedio-monitor-model"
```
