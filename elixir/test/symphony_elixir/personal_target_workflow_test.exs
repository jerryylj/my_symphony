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

    assert {:ok, %{config: config, prompt: prompt, source_paths: source_paths}} = Workflow.load(path)
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

    assert source_paths |> Enum.map(&Path.basename/1) ==
             ["WORKFLOW.md", "github-serial.yml", "github-serial.md"]

    assert prompt =~ "value from the `origin`"
    refute prompt =~ "jerryylj/vedio_monitor_model"
    assert prompt =~ "Refs #<current_number>"
    refute prompt =~ "Closes #<current_number>"
    assert prompt =~ "successor_number = current_number + 1"
    assert prompt =~ "`ready-for-agent` is Matt's triage label"
    assert prompt =~ "`agent-ready` is Symphony's dispatch label"
    assert prompt =~ "`ready-for-agent` never substitutes for `agent-ready`"
    assert prompt =~ "Having only `ready-for-agent` means `agent-ready` is missing"
    assert prompt =~ "then `GET /repos/<repository>/issues/{successor_number}` again"
    assert prompt =~ "Only after confirming that the immediate successor"
    assert prompt =~ "Never label a successor while the current issue is unmerged"
  end

  test "stock manage target workflow preserves its bounded turn policy" do
    path = Path.expand("../../../my/stock_manage/WORKFLOW.md", __DIR__)
    previous_github_token = System.get_env("GITHUB_TOKEN")

    on_exit(fn ->
      if previous_github_token do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end
    end)

    assert {:ok, %{config: config, prompt: prompt, source_paths: source_paths}} = Workflow.load(path)
    System.put_env("GITHUB_TOKEN", "test-github-token")
    assert {:ok, settings} = Schema.parse(config)
    assert :ok = Config.validate_settings(settings)

    assert settings.tracker.provider["repo"] == "jerryylj/stock_manage"
    assert settings.agent.max_turns == 40
    assert settings.agent.block_on_max_turns

    assert source_paths |> Enum.map(&Path.basename/1) ==
             ["WORKFLOW.md", "github-serial.yml", "github-serial.md"]

    assert prompt =~ "value from the `origin`"
    refute prompt =~ "jerryylj/stock_manage"
    assert prompt =~ "Having only `ready-for-agent` means `agent-ready` is missing"
  end

  test "GitHub target workflows supply each issue workspace with network access" do
    paths = [
      Path.expand("../../../my/WORKFLOW.md", __DIR__),
      Path.expand("../../../my/stock_manage/WORKFLOW.md", __DIR__),
      Path.expand("../../../my/vedio_monitor_model/WORKFLOW.md", __DIR__)
    ]

    previous_github_token = System.get_env("GITHUB_TOKEN")
    System.put_env("GITHUB_TOKEN", "test-github-token")

    on_exit(fn ->
      if previous_github_token do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end
    end)

    Enum.each(paths, fn path ->
      assert {:ok, %{config: config}} = Workflow.load(path)
      assert {:ok, settings} = Schema.parse(config)

      assert {:ok, policy} =
               Schema.resolve_runtime_turn_sandbox_policy(settings, System.tmp_dir!())

      assert policy["type"] == "workspaceWrite"
      assert policy["networkAccess"]
      assert policy["writableRoots"] != []
    end)
  end
end
