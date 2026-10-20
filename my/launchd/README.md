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
