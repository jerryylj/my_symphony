defmodule SymphonyElixir.GitHub.Completion do
  @moduledoc """
  Verifies GitHub delivery and performs the serial issue handoff for an opted-in workflow.

  The agent supplies only a PR hint. Issue identity and repository come from the
  session-bound tracker settings, and all decisions use fresh GitHub responses.
  """

  require Logger

  @page_size 100

  @marker_prefix "<!-- symphony-completion:pr="
  @intent_prefix "<!-- symphony-close-intent:pr="

  @spec run(term(), {:ok, term()}, {:ok, term()}, function()) :: {:ok, map()} | {:error, term()}
  def run(arguments, {:ok, issue}, {:ok, tracker_settings}, client) when is_function(client, 5) do
    with {:ok, repo, number, requested_pr} <- validate_request(arguments, issue, tracker_settings),
         {:ok, current} <- get(client, tracker_settings, "/repos/#{repo}/issues/#{number}"),
         {:ok, issue_state} <- validate_current(current, number, requested_pr, client, tracker_settings, repo),
         {:ok, candidates} <- candidates(client, tracker_settings, repo, number),
         {:ok, {pr_number, referenced_at}} <- select_pr(candidates, requested_pr),
         {:ok, repository} <- get(client, tracker_settings, "/repos/#{repo}"),
         {:ok, pr} <- get(client, tracker_settings, "/repos/#{repo}/pulls/#{pr_number}"),
         :ok <- validate_pr(pr, repository, repo, pr_number, referenced_at),
         :ok <- handoff(client, tracker_settings, repo, number),
         :ok <- finish(client, tracker_settings, repo, number, pr_number, issue_state) do
      Logger.info("GitHub completion verified issue=GH-#{number} repo=#{repo} pr=#{pr_number}")
      {:ok, %{"outcome" => "completed", "pr_number" => pr_number}}
    else
      {:reject, outcome} ->
        log_rejection(issue, outcome)
        {:ok, %{"outcome" => outcome}}

      {:http_error, status} when status in [403, 422] ->
        {:ok, %{"outcome" => "external_blocker", "status" => status}}

      {:http_error, status} ->
        {:error, {:github_http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def run(_arguments, _issue, _tracker_settings, _client), do: {:ok, %{"outcome" => "invalid_request"}}

  defp log_rejection(issue, outcome) do
    identifier = if is_map(issue), do: Map.get(issue, :identifier), else: "unknown"
    context = "GitHub completion rejected issue=#{identifier} outcome=#{outcome}"

    if outcome in ["no_pr", "open_pr"] do
      Logger.info(context)
    else
      Logger.warning(context)
    end
  end

  @spec audit_closed(term(), map(), function()) :: :ok | {:error, term()}
  def audit_closed(%{id: number, url: url}, %{provider: %{"repo" => repo}} = settings, client)
      when is_binary(number) and is_binary(repo) and is_function(client, 5) do
    if is_binary(url) and String.ends_with?(url, "/#{repo}/issues/#{number}") do
      audit_matching_closed(client, settings, repo, number, url)
    else
      {:error, :repository_mismatch}
    end
  end

  def audit_closed(_issue, _settings, _client), do: {:error, :invalid_audit_context}

  defp audit_matching_closed(client, settings, repo, number, url) do
    path = "/repos/#{repo}/issues/#{number}"

    with {:ok, %{"state" => "closed", "closed_at" => closed_at} = current} <- get(client, settings, path),
         {:ok, [pr_number]} <- intent_prs(client, settings, repo, number, current),
         {:ok, marked?} <- marker_present?(client, settings, repo, number, pr_number, closed_at) do
      if marked?, do: :ok, else: recover_close(client, settings, number, url, pr_number)
    else
      {:ok, []} -> {:error, :out_of_band_closure}
      {:ok, _multiple} -> {:error, :ambiguous_close_intent}
      other -> {:error, {:audit_failed, other}}
    end
  end

  defp recover_close(client, settings, number, url, pr_number) do
    issue = %{id: number, identifier: "GH-#{number}", url: url}

    case run(%{"pr_number" => pr_number}, {:ok, issue}, {:ok, settings}, client) do
      {:ok, %{"outcome" => "completed"}} -> :ok
      other -> {:error, {:recovery_failed, other}}
    end
  end

  defp validate_request(arguments, issue, %{provider: %{"repo" => repo}})
       when is_map(arguments) and is_map(issue) and is_binary(repo) do
    number = Map.get(issue, :id)
    url = Map.get(issue, :url)
    requested_pr = Map.get(arguments, "pr_number")

    with :ok <- validate_request_fields(arguments, number, requested_pr),
         :ok <- validate_issue_url(url, repo, number) do
      {:ok, repo, number, requested_pr}
    end
  end

  defp validate_request(_arguments, _issue, _settings), do: {:reject, "invalid_request"}

  defp validate_request_fields(arguments, number, requested_pr) do
    valid_number? = is_binary(number) and String.match?(number, ~r/^[1-9][0-9]*$/)
    valid_pr? = is_nil(requested_pr) or (is_integer(requested_pr) and requested_pr > 0)

    if Map.keys(arguments) -- ["pr_number"] == [] and valid_number? and valid_pr? do
      :ok
    else
      {:reject, "invalid_request"}
    end
  end

  defp validate_issue_url(url, repo, number) do
    if is_binary(url) and String.ends_with?(url, "/#{repo}/issues/#{number}") do
      :ok
    else
      {:reject, "repository_mismatch"}
    end
  end

  defp validate_current(%{"state" => "open", "number" => number}, expected, _requested_pr, _client, _settings, _repo)
       when is_integer(number) do
    if Integer.to_string(number) == expected, do: {:ok, :open}, else: {:reject, "issue_mismatch"}
  end

  defp validate_current(%{"state" => "closed", "number" => number} = current, expected, requested_pr, client, settings, repo)
       when is_integer(number) do
    cond do
      Integer.to_string(number) != expected -> {:reject, "issue_mismatch"}
      not is_integer(requested_pr) -> {:reject, "out_of_band_closure"}
      true -> validate_closed_current(client, settings, repo, expected, requested_pr, current)
    end
  end

  defp validate_current(_current, _expected, _requested, _client, _settings, _repo),
    do: {:error, :invalid_issue_response}

  defp validate_closed_current(client, settings, repo, number, pr_number, current) do
    with {:ok, :recoverable} <- validate_close_intent(client, settings, repo, number, pr_number, current),
         {:ok, marked?} <- marker_present?(client, settings, repo, number, pr_number, current["closed_at"]) do
      if marked?, do: {:ok, :closed}, else: {:ok, :recoverable}
    end
  end

  defp finish(_client, _settings, _repo, _number, _pr_number, :closed), do: :ok

  defp finish(client, settings, repo, number, pr_number, :recoverable) do
    write_marker(client, settings, "/repos/#{repo}/issues/#{number}", pr_number)
  end

  defp finish(client, settings, repo, number, pr_number, :open) do
    path = "/repos/#{repo}/issues/#{number}"

    with :ok <- ensure_intent(client, settings, repo, number, pr_number),
         {:ok, closed} <- patch(client, settings, path, %{"state" => "closed"}),
         true <- (closed["state"] == "closed" and is_binary(closed["closed_at"])) or {:error, :close_not_confirmed},
         {:ok, intents} <- intent_prs(client, settings, repo, number, closed),
         true <- intents == [pr_number] or {:error, :close_not_attributable} do
      write_marker(client, settings, path, pr_number)
    end
  end

  defp ensure_intent(client, settings, repo, number, pr_number) do
    path = "/repos/#{repo}/issues/#{number}"

    with {:ok, existing} <- intent_prs(client, settings, repo, number, nil) do
      maybe_write_intent(client, settings, path, pr_number, existing)
    end
  end

  defp maybe_write_intent(client, settings, path, pr_number, existing) do
    if pr_number in existing, do: :ok, else: post_intent(client, settings, path, pr_number)
  end

  defp post_intent(client, settings, path, pr_number) do
    case request(client, settings, "POST", path <> "/comments", %{}, %{"body" => intent(pr_number)}) do
      {:ok, _} -> :ok
      other -> other
    end
  end

  defp validate_close_intent(client, settings, repo, number, pr_number, current) do
    case intent_prs(client, settings, repo, number, current) do
      {:ok, [^pr_number]} -> {:ok, :recoverable}
      {:ok, _} -> {:reject, "out_of_band_closure"}
      other -> other
    end
  end

  defp intent_prs(client, settings, repo, number, current) do
    path = "/repos/#{repo}/issues/#{number}/comments"
    fetch_intent_page(client, settings, path, current, 1, MapSet.new())
  end

  defp fetch_intent_page(client, settings, path, current, page, found) do
    with {:ok, comments} <- request(client, settings, "GET", path, %{"per_page" => @page_size, "page" => page}, nil),
         true <- is_list(comments) or {:error, :invalid_comments_response} do
      updated = Enum.reduce(comments, found, &collect_intent(&1, &2, current))

      if length(comments) < @page_size do
        {:ok, updated |> MapSet.to_list() |> Enum.sort()}
      else
        fetch_intent_page(client, settings, path, current, page + 1, updated)
      end
    end
  end

  defp collect_intent(comment, found, current) do
    case intent_pr(comment, current) do
      nil -> found
      pr -> MapSet.put(found, pr)
    end
  end

  defp intent_pr(%{"body" => body} = comment, current) when is_binary(body) do
    case Regex.run(~r/^<!-- symphony-close-intent:pr=([1-9][0-9]*) -->$/, body) do
      [_, number] -> if valid_intent_time_and_actor?(comment, current), do: String.to_integer(number)
      _ -> nil
    end
  end

  defp intent_pr(_comment, _current), do: nil

  defp valid_intent_time_and_actor?(_comment, nil), do: true

  defp valid_intent_time_and_actor?(comment, %{"closed_at" => closed_at, "closed_by" => %{"id" => actor_id}})
       when is_integer(actor_id) do
    comment["user"]["id"] == actor_id and before_close?(comment, closed_at)
  end

  defp valid_intent_time_and_actor?(_comment, _current), do: false

  defp before_close?(%{"created_at" => comment_at}, closed_at)
       when is_binary(comment_at) and is_binary(closed_at) do
    with {:ok, comment, _} <- DateTime.from_iso8601(comment_at),
         {:ok, closed, _} <- DateTime.from_iso8601(closed_at) do
      DateTime.compare(comment, closed) in [:eq, :lt]
    else
      _ -> false
    end
  end

  defp before_close?(_comment, _closed_at), do: false

  defp write_marker(client, settings, path, pr_number) do
    marker = marker(pr_number)

    case request(client, settings, "POST", path <> "/comments", %{}, %{"body" => marker}) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("GitHub close receipt pending path=#{path} pr=#{pr_number} reason=#{inspect(other)}")
        :ok
    end
  end

  defp marker_present?(client, settings, repo, number, pr_number, closed_at) do
    path = "/repos/#{repo}/issues/#{number}/comments"
    fetch_marker_page(client, settings, path, pr_number, closed_at, 1)
  end

  defp fetch_marker_page(client, settings, path, pr_number, closed_at, page) do
    with {:ok, comments} <- request(client, settings, "GET", path, %{"per_page" => @page_size, "page" => page}, nil),
         true <- is_list(comments) or {:error, :invalid_comments_response} do
      cond do
        Enum.any?(comments, &(marker_comment?(&1, pr_number) and after_close?(&1, closed_at))) -> {:ok, true}
        length(comments) < @page_size -> {:ok, false}
        true -> fetch_marker_page(client, settings, path, pr_number, closed_at, page + 1)
      end
    end
  end

  defp marker(pr_number), do: @marker_prefix <> Integer.to_string(pr_number) <> " -->"
  defp intent(pr_number), do: @intent_prefix <> Integer.to_string(pr_number) <> " -->"

  defp marker_comment?(%{"body" => body}, :any) when is_binary(body),
    do: String.starts_with?(body, @marker_prefix) and String.ends_with?(body, " -->")

  defp marker_comment?(%{"body" => body}, pr_number) when is_integer(pr_number), do: body == marker(pr_number)
  defp marker_comment?(_comment, _pr_number), do: false

  defp after_close?(%{"created_at" => comment_at}, closed_at)
       when is_binary(comment_at) and is_binary(closed_at) do
    with {:ok, comment, _} <- DateTime.from_iso8601(comment_at),
         {:ok, closed, _} <- DateTime.from_iso8601(closed_at) do
      DateTime.compare(comment, closed) in [:eq, :gt]
    else
      _ -> false
    end
  end

  defp after_close?(_comment, _closed_at), do: false

  defp candidates(client, settings, repo, number) do
    path = "/repos/#{repo}/issues/#{number}/timeline"
    fetch_timeline(client, settings, path, repo, 1, %{})
  end

  @spec associated_pr?(term(), term(), pos_integer(), function()) :: {:ok, boolean()} | {:error, term()}
  def associated_pr?(%{id: number, url: url}, %{provider: %{"repo" => repo}} = settings, pr_number, client)
      when is_binary(number) and is_binary(repo) and is_integer(pr_number) and pr_number > 0 and
             is_function(client, 5) do
    with :ok <- validate_issue_url(url, repo, number),
         {:ok, linked} <- candidates(client, settings, repo, number) do
      {:ok, Enum.any?(linked, fn {candidate, _at} -> candidate == pr_number end)}
    else
      {:reject, _reason} -> {:error, :invalid_pr_binding}
      other -> other
    end
  end

  def associated_pr?(_issue, _settings, _pr_number, _client), do: {:error, :invalid_pr_binding}

  defp fetch_timeline(client, settings, path, repo, page, seen) do
    with {:ok, events} <- request(client, settings, "GET", path, %{"per_page" => @page_size, "page" => page}, nil),
         true <- is_list(events) or {:error, :invalid_timeline_response} do
      updated = Enum.reduce(events, seen, &add_candidate(&1, &2, repo))

      if length(events) < @page_size do
        {:ok, updated |> Map.to_list() |> Enum.sort()}
      else
        fetch_timeline(client, settings, path, repo, page + 1, updated)
      end
    end
  end

  defp add_candidate(event, candidates, repo) do
    case candidate_ref(event, repo) do
      nil -> candidates
      {number, created_at} -> Map.update(candidates, number, created_at, &min(&1, created_at))
    end
  end

  defp candidate_ref(%{"event" => "cross-referenced", "created_at" => created_at, "source" => %{"issue" => source}}, repo)
       when is_map(source) do
    pr = source["pull_request"]
    source_repo = get_in(source, ["repository", "full_name"])
    number = source["number"]

    if is_map(pr) and is_integer(number) and number > 0 and is_binary(created_at) and
         (source_repo == repo or String.ends_with?(to_string(source["html_url"]), "/#{repo}/pull/#{number}")) do
      {number, created_at}
    end
  end

  defp candidate_ref(_event, _repo), do: nil

  defp select_pr([], nil), do: {:reject, "no_pr"}
  defp select_pr([], _requested), do: {:reject, "unrelated_pr"}
  defp select_pr([candidate], nil), do: {:ok, candidate}
  defp select_pr([{number, _} = candidate], number), do: {:ok, candidate}
  defp select_pr([_number], _requested), do: {:reject, "unrelated_pr"}
  defp select_pr(_numbers, _requested), do: {:reject, "ambiguous_pr"}

  defp validate_pr(pr, repository, repo, number, referenced_at) when is_map(pr) and is_map(repository) do
    with :ok <- validate_pr_identity(pr, repo, number),
         :ok <- validate_pr_base(pr, repository) do
      validate_pr_merge(pr, referenced_at)
    end
  end

  defp validate_pr(_pr, _repository, _repo, _number, _referenced_at), do: {:error, :invalid_pr_response}

  defp validate_pr_identity(pr, repo, number) do
    cond do
      pr["number"] != number -> {:reject, "unrelated_pr"}
      get_in(pr, ["base", "repo", "full_name"]) != repo -> {:reject, "wrong_repository"}
      true -> :ok
    end
  end

  defp validate_pr_base(pr, repository) do
    if get_in(pr, ["base", "ref"]) == repository["default_branch"] do
      :ok
    else
      {:reject, "wrong_base"}
    end
  end

  defp validate_pr_merge(pr, referenced_at) do
    cond do
      pr["merged"] == true and pr["state"] == "closed" and is_binary(pr["merged_at"]) and
          referenced_at <= pr["merged_at"] ->
        :ok

      pr["merged"] == true ->
        {:reject, "unrelated_pr"}

      pr["state"] == "open" ->
        {:reject, "open_pr"}

      true ->
        {:reject, "unmerged_pr"}
    end
  end

  defp handoff(client, settings, repo, number) do
    successor = String.to_integer(number) + 1
    path = "/repos/#{repo}/issues/#{successor}"

    case request(client, settings, "GET", path, %{}, nil) do
      {:ok, %{"state" => "open", "number" => ^successor} = issue} ->
        if Map.has_key?(issue, "pull_request") do
          :ok
        else
          ensure_dispatch_label(client, settings, path, issue)
        end

      {:ok, %{"state" => "closed", "number" => ^successor}} ->
        :ok

      {:http_error, 404} ->
        :ok

      {:ok, _other} ->
        {:error, :invalid_successor_response}

      {:error, reason} ->
        {:error, reason}

      {:http_error, status} ->
        {:http_error, status}
    end
  end

  defp ensure_dispatch_label(client, settings, path, issue) do
    if dispatch_label?(issue) do
      :ok
    else
      with {:ok, _} <- request(client, settings, "POST", path <> "/labels", %{}, %{"labels" => ["agent-ready"]}),
           {:ok, confirmed} <- get(client, settings, path),
           true <- dispatch_label?(confirmed) or {:error, :successor_label_not_confirmed} do
        :ok
      end
    end
  end

  defp dispatch_label?(issue) do
    Enum.any?(issue["labels"] || [], fn
      %{"name" => "agent-ready"} -> true
      "agent-ready" -> true
      _ -> false
    end)
  end

  defp get(client, settings, path), do: request(client, settings, "GET", path, %{}, nil)
  defp patch(client, settings, path, body), do: request(client, settings, "PATCH", path, %{}, body)

  defp request(client, settings, method, path, params, body) do
    case client.(method, path, params, body, tracker_settings: settings) do
      {:ok, %{status: status, body: response}} when status in 200..299 ->
        {:ok, response}

      {:ok, %{status: 403, body: %{"message" => message}}} when is_binary(message) ->
        if String.contains?(String.downcase(message), "rate limit") do
          {:error, :github_rate_limited}
        else
          {:http_error, 403}
        end

      {:ok, %{status: status}} when is_integer(status) ->
        {:http_error, status}

      {:error, reason} ->
        {:error, reason}

      _ ->
        {:error, :invalid_github_response}
    end
  end
end
