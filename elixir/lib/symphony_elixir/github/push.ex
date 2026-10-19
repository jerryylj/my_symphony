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
         {:ok, _output} <- git(workspace, ["push", "-u", "origin", "HEAD"]) do
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
    if origin in ["git@github.com:#{repo}.git", "git@github.com:#{repo}", "https://github.com/#{repo}.git", "https://github.com/#{repo}"] do
      :ok
    else
      {:error, :repository_mismatch}
    end
  end

  defp verify_branch("", _default), do: {:error, :detached_head}
  defp verify_branch(branch, branch), do: {:error, :default_branch_push_denied}
  defp verify_branch(_branch, _default), do: :ok

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
end
