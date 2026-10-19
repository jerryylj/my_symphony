defmodule SymphonyElixir.GitHub.PushTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{AgentTool, Push}

  test "host push publishes the current feature branch through a verified GitHub origin" do
    root = Path.join(System.tmp_dir!(), "symphony-push-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-42")
    bare = Path.join(root, "remote.git")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    {_, 0} = System.cmd("git", ["init", "--bare", "--initial-branch=main", bare])
    {_, 0} = System.cmd("git", ["init", "-b", "feature-42", workspace])
    File.write!(Path.join(workspace, "work.txt"), "done\n")
    {_, 0} = System.cmd("git", ["add", "work.txt"], cd: workspace)
    {_, 0} = System.cmd("git", ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-m", "work"], cd: workspace)
    {_, 0} = System.cmd("git", ["remote", "add", "origin", "git@github.com:octo/repo.git"], cd: workspace)
    {_, 0} = System.cmd("git", ["config", "remote.origin.pushurl", bare], cd: workspace)

    response =
      AgentTool.execute("github_push_branch", %{},
        completion_policy: "merged_pr",
        workspace: workspace,
        workspace_root: root,
        tracker_settings: %{provider: %{"repo" => "octo/repo"}},
        github_client: fn "GET", "/repos/octo/repo", %{}, nil, _opts ->
          {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
        end
      )

    assert response["success"]
    assert %{"outcome" => "pushed", "branch" => "feature-42"} = Jason.decode!(response["output"])
    {sha, 0} = System.cmd("git", ["--git-dir", bare, "rev-parse", "refs/heads/feature-42"])
    assert String.trim(sha) =~ ~r/^[0-9a-f]{40}$/
  end

  test "host push refuses a workspace whose origin is outside the configured repository" do
    root = Path.join(System.tmp_dir!(), "symphony-push-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-42")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    {_, 0} = System.cmd("git", ["init", "-b", "feature-42", workspace])
    {_, 0} = System.cmd("git", ["remote", "add", "origin", "git@github.com:other/repo.git"], cd: workspace)

    assert {:error, :repository_mismatch} =
             Push.run(%{},
               workspace: workspace,
               workspace_root: root,
               tracker_settings: %{provider: %{"repo" => "octo/repo"}},
               github_client: fn _, _, _, _, _ -> flunk("wrong origin must not reach GitHub") end
             )
  end

  test "host push refuses the default branch even when origin matches" do
    root = Path.join(System.tmp_dir!(), "symphony-push-#{System.unique_integer([:positive])}")
    workspace = Path.join(root, "GH-42")
    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf(root) end)

    {_, 0} = System.cmd("git", ["init", "-b", "main", workspace])
    {_, 0} = System.cmd("git", ["remote", "add", "origin", "git@github.com:octo/repo.git"], cd: workspace)

    assert {:error, :default_branch_push_denied} =
             Push.run(%{},
               workspace: workspace,
               workspace_root: root,
               tracker_settings: %{provider: %{"repo" => "octo/repo"}},
               github_client: fn "GET", "/repos/octo/repo", %{}, nil, _opts ->
                 {:ok, %{status: 200, body: %{"default_branch" => "main"}}}
               end
             )
  end
end
