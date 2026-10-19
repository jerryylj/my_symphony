defmodule SymphonyElixir.PersonalTargetWorkflowTest do
  use ExUnit.Case, async: false

  alias SymphonyElixir.Config
  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.PromptBuilder
  alias SymphonyElixir.Tracker.Issue
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
    assert settings.tracker.provider["repo"] == "kunkun-code-org/vedio_monitor_model"
    assert settings.tracker.required_labels == ["agent-ready"]
    assert settings.tracker.active_states == ["open"]
    assert settings.tracker.terminal_states == ["closed"]
    assert settings.agent.max_concurrent_agents == 1
    assert settings.hooks.timeout_ms == 300_000

    assert settings.hooks.after_create =~ "git clone --depth 1 git@github.com:kunkun-code-org/vedio_monitor_model.git ."
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
    refute prompt =~ "kunkun-code-org/vedio_monitor_model"
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
    previous_smoke_verification = System.get_env("SYMPHONY_GITHUB_AUTO_CLOSE_SMOKE_VERIFIED")

    on_exit(fn ->
      if previous_github_token do
        System.put_env("GITHUB_TOKEN", previous_github_token)
      else
        System.delete_env("GITHUB_TOKEN")
      end

      if previous_smoke_verification do
        System.put_env("SYMPHONY_GITHUB_AUTO_CLOSE_SMOKE_VERIFIED", previous_smoke_verification)
      else
        System.delete_env("SYMPHONY_GITHUB_AUTO_CLOSE_SMOKE_VERIFIED")
      end
    end)

    assert {:ok, %{config: config, prompt: prompt, source_paths: source_paths}} = Workflow.load(path)
    System.put_env("GITHUB_TOKEN", "test-github-token")
    assert {:ok, settings} = Schema.parse(config)
    System.delete_env("SYMPHONY_GITHUB_AUTO_CLOSE_SMOKE_VERIFIED")
    assert {:error, :github_auto_close_smoke_not_verified} = Config.validate_settings(settings)
    System.put_env("SYMPHONY_GITHUB_AUTO_CLOSE_SMOKE_VERIFIED", "kunkun-code-org/stock_manage")
    assert :ok = Config.validate_settings(settings)

    assert settings.tracker.provider["repo"] == "kunkun-code-org/stock_manage"
    assert settings.tracker.completion_policy == "merged_pr"

    assert {:error, :merged_pr_requires_network_isolated_agent} =
             Config.validate_settings(%{settings | codex: %{settings.codex | turn_sandbox_policy: %{"type" => "workspaceWrite", "networkAccess" => true}}})

    assert settings.agent.max_turns == 40
    assert settings.agent.block_on_max_turns

    assert source_paths |> Enum.map(&Path.basename/1) ==
             ["WORKFLOW.md", "github-serial.yml", "github-serial.md"]

    assert prompt =~ "value from the `origin`"
    refute prompt =~ "jerryylj/stock_manage"
    assert prompt =~ "Having only `ready-for-agent` means `agent-ready` is missing"

    previous_path = Workflow.workflow_file_path()
    on_exit(fn -> Workflow.set_workflow_file_path(previous_path) end)
    Workflow.set_workflow_file_path(path)

    rendered =
      PromptBuilder.build_prompt(
        %Issue{
          id: "42",
          identifier: "GH-42",
          title: "Example",
          state: "open",
          url: "https://github.com/kunkun-code-org/stock_manage/issues/42"
        },
        completion_policy: "merged_pr"
      )

    assert rendered =~ "github_complete_issue"
    assert rendered =~ "github_push_branch"
    refute rendered =~ "gh pr merge"
    refute rendered =~ "git push -u"
  end

  test "merged-PR workflows isolate the agent shell from GitHub while other workflows keep network access" do
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
      assert policy["networkAccess"] == (settings.tracker.completion_policy != "merged_pr")
      assert policy["writableRoots"] != []
    end)
  end
end
