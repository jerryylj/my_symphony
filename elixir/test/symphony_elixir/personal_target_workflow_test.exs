defmodule SymphonyElixir.PersonalTargetWorkflowTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.Workflow

  test "vedio monitor target workflow parses, validates, and requires strict serial dispatch" do
    path = Path.expand("../../../my/vedio_monitor_model/WORKFLOW.md", __DIR__)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous_github_token do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end
    end)

    assert {:ok, %{config: config, prompt: prompt}} = Workflow.load(path)
    System.put_env("GITHUB_TOKEN", "test-github-token")
    assert {:ok, settings} = Schema.parse(config)
    assert :ok = Config.validate_settings(settings)

    assert settings.tracker.kind == "github"
    assert settings.tracker.provider["repo"] == "jerryylj/vedio_monitor_model"
    assert settings.tracker.required_labels == ["agent-ready"]
    assert settings.tracker.active_states == ["open"]
    assert settings.tracker.terminal_states == ["closed"]
    assert settings.agent.max_concurrent_agents == 1
    assert settings.hooks.timeout_ms == 300_000

    assert settings.hooks.after_create =~ "gh repo clone jerryylj/vedio_monitor_model ."
    assert settings.hooks.after_create =~ "GIT_CONFIG_VALUE_0=HTTP/1.1"
    assert settings.hooks.after_create =~ "http_proxy=http://127.0.0.1:7890"
    refute settings.codex.command =~ "--profile"
    assert settings.codex.command =~ ~s(model="ark-code-latest")
    assert settings.codex.command =~ ~s(model_provider="volcengine")
    assert settings.codex.command =~ ~s(model_reasoning_effort="low")
    assert settings.codex.command =~ "model_providers.volcengine.base_url"

    Enum.each(
      [
        "http_proxy",
        "https_proxy",
        "all_proxy",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "ALL_PROXY",
        "no_proxy",
        "NO_PROXY"
      ],
      fn proxy_variable ->
        assert settings.codex.command =~ "-u #{proxy_variable}"
      end
    )

    assert prompt =~ "jerryylj/vedio_monitor_model"
    assert prompt =~ "successor_number = current_number + 1"
    assert prompt =~ "Never label a successor while the current issue is unmerged"
  end
end
