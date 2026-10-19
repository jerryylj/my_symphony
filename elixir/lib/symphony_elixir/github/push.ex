defmodule SymphonyElixir.GitHub.Push do
  @moduledoc """
  Pushes the current feature branch from a session workspace on Symphony's host.

  The opted-in coding agent has no direct network access. This operation accepts
  no command, remote, path, or branch arguments from the agent.
  """

  alias SymphonyElixir.GitHub.Client
  alias SymphonyElixir.PathSafety

  @spec run(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(arguments, opts) when arguments == %{} do
    with {:ok, workspace} <- fetch_option(opts, :workspace),
         {:ok, root} <- fetch_option(opts, :workspace_root),
         {:ok, settings} <- fetch_option(opts, :tracker_settings),
         {:ok, repo} <- repository(settings),
         :ok <- verify_workspace(workspace, root),
         {:ok, origin} <- git(workspace, ["remote", "get-url", "origin"]),
         :ok <- verify_origin(String.trim(origin), repo),
         {:ok, branch} <- git(workspace, ["branch", "--show-current"]),
         {:ok, default_branch} <- default_branch(settings, repo, opts),
         :ok <- verify_branch(String.trim(branch), default_branch),
         :ok <- publish_from_isolated_repository(workspace, repo, String.trim(branch), opts) do
      {:ok, %{"outcome" => "pushed", "branch" => String.trim(branch)}}
    end
  end

  def run(_arguments, _opts), do: {:error, :invalid_push_request}

  defp fetch_option(opts, key) do
    case Keyword.fetch(opts, key) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, {:missing_push_option, key}}
    end
  end

  defp repository(%{provider: %{"repo" => repo}}) when is_binary(repo), do: {:ok, repo}
  defp repository(_settings), do: {:error, :missing_github_repo}

  defp verify_workspace(workspace, root) when is_binary(workspace) and is_binary(root) do
    with {:ok, actual} <- PathSafety.canonicalize(workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(root),
         true <- String.starts_with?(actual, canonical_root <> "/") do
      :ok
    else
      _ -> {:error, :workspace_outside_root}
    end
  end

  defp verify_workspace(_workspace, _root), do: {:error, :workspace_outside_root}

  defp verify_origin(origin, repo) do
    legacy_stock_origin? =
      repo == "kunkun-code-org/stock_manage" and
        origin in [
          "git@github.com:jerryylj/stock_manage.git",
          "git@github.com:jerryylj/stock_manage",
          "https://github.com/jerryylj/stock_manage.git",
          "https://github.com/jerryylj/stock_manage"
        ]

    if legacy_stock_origin? or
         origin in ["git@github.com:#{repo}.git", "git@github.com:#{repo}", "https://github.com/#{repo}.git", "https://github.com/#{repo}"] do
      :ok
    else
      {:error, :repository_mismatch}
    end
  end

  defp verify_branch("", _default), do: {:error, :detached_head}
  defp verify_branch(branch, branch), do: {:error, :default_branch_push_denied}

  defp verify_branch(branch, _default) do
    if String.starts_with?(branch, "-") or
         match?({_, status} when status != 0, System.cmd("git", ["check-ref-format", "--branch", branch])) do
      {:error, :invalid_feature_branch}
    else
      :ok
    end
  end

  defp publish_from_isolated_repository(workspace, repo, branch, opts) do
    temporary = Path.join(System.tmp_dir!(), "symphony-git-push-#{Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)}")
    destination = Keyword.get(opts, :test_push_url, "git@github.com:#{repo}.git")
    bundle = Path.join(temporary, "branch.bundle")

    try do
      with :ok <- File.mkdir(temporary),
           :ok <- File.chmod(temporary, 0o700),
           {:ok, _} <- safe_git(workspace, ["bundle", "create", bundle, branch]),
           {:ok, _} <- safe_git(temporary, ["init", "--bare", "."]),
           {:ok, _} <- safe_git(temporary, ["fetch", "--no-tags", bundle, branch]),
           {:ok, _} <- safe_git(temporary, ["push", destination, "FETCH_HEAD:refs/heads/#{branch}"]) do
        :ok
      end
    after
      File.rm_rf(temporary)
    end
  end

  defp default_branch(settings, repo, opts) do
    client = Keyword.get(opts, :github_client, &Client.request/5)

    case client.("GET", "/repos/#{repo}", %{}, nil, tracker_settings: settings) do
      {:ok, %{status: 200, body: %{"default_branch" => branch}}} when is_binary(branch) ->
        {:ok, branch}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :default_branch_unavailable}
    end
  end

  defp git(workspace, args) do
    case System.cmd("git", args, cd: workspace, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_failed, hd(args), status}}
    end
  rescue
    error -> {:error, {:git_failed, hd(args), error}}
  end

  defp safe_git(directory, args) do
    env = [
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_NO_LAZY_FETCH", "1"},
      {"GIT_CONFIG_COUNT", "2"},
      {"GIT_CONFIG_KEY_0", "core.hooksPath"},
      {"GIT_CONFIG_VALUE_0", "/dev/null"},
      {"GIT_CONFIG_KEY_1", "protocol.ext.allow"},
      {"GIT_CONFIG_VALUE_1", "never"}
    ]

    case System.cmd("git", args, cd: directory, env: env, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {_output, status} -> {:error, {:git_failed, hd(args), status}}
    end
  rescue
    error -> {:error, {:git_failed, hd(args), error}}
  end
end
