defmodule SymphonyElixir.GitHub.CompletionTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.GitHub.{AgentTool, Completion}
  alias SymphonyElixir.Tracker.Issue

  @settings %{provider: %{"repo" => "octo/repo", "token" => "test-token"}}
  @issue %Issue{id: "42", identifier: "GH-42", state: "open", url: "https://github.com/octo/repo/issues/42"}

  test "completion request with no associated PR keeps the issue open" do
    response =
      AgentTool.execute("github_complete_issue", %{},
        completion_policy: "merged_pr",
        tracker_settings: @settings,
        issue: @issue,
        github_client: fn method, path, _params, _body, _opts ->
          send(self(), {:request, method, path})

          case path do
            "/repos/octo/repo/issues/42" -> {:ok, %{status: 200, body: %{"state" => "open", "number" => 42}}}
            "/repos/octo/repo/issues/42/timeline" -> {:ok, %{status: 200, body: []}}
          end
        end
      )

    refute response["success"]
    assert %{"outcome" => "no_pr"} = Jason.decode!(response["output"])
    assert_received {:request, "GET", "/repos/octo/repo/issues/42"}
    assert_received {:request, "GET", "/repos/octo/repo/issues/42/timeline"}
    refute_received {:request, "PATCH", _}
  end

  test "an open PR leaves the issue and immediate successor unchanged" do
    response =
      AgentTool.execute(
        "github_complete_issue",
        %{"pr_number" => 57},
        completion_opts(%{
          "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
          "/repos/octo/repo/issues/42/timeline" => [cross_reference(57)],
          "/repos/octo/repo" => %{"default_branch" => "main"},
          "/repos/octo/repo/pulls/57" => pr(57, "open", false)
        })
      )

    refute response["success"]
    assert %{"outcome" => "open_pr"} = Jason.decode!(response["output"])
    refute_received {:request, "PATCH", _, _}
    refute_received {:request, "POST", _, _}
  end

  test "GitHub rate limiting is retryable while a permission denial is a blocker" do
    for {message, outcome} <- [{"API rate limit exceeded", "transient_error"}, {"Resource not accessible by integration", "external_blocker"}] do
      response =
        AgentTool.execute("github_complete_issue", %{},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn "GET", "/repos/octo/repo/issues/42", _, _, _ ->
            {:ok, %{status: 403, body: %{"message" => message}}}
          end
        )

      refute response["success"]
      assert %{"outcome" => ^outcome} = Jason.decode!(response["output"])
    end
  end

  test "a merged associated PR releases exactly the next issue before closing current" do
    responses = %{
      "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
      "/repos/octo/repo/issues/42/timeline" => [cross_reference(57)],
      "/repos/octo/repo" => %{"default_branch" => "main"},
      "/repos/octo/repo/pulls/57" => pr(57, "closed", true),
      "/repos/octo/repo/issues/43" => %{"state" => "open", "number" => 43, "labels" => [%{"name" => "agent-ready"}]}
    }

    response = AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, completion_opts(responses))

    assert response["success"]
    assert %{"outcome" => "completed", "pr_number" => 57} = Jason.decode!(response["output"])
    assert_received {:request, "GET", "/repos/octo/repo/issues/43", nil}
    assert_received {:request, "PATCH", "/repos/octo/repo/issues/42", %{"state" => "closed"}}
    assert_received {:request, "POST", "/repos/octo/repo/issues/42/comments", %{"body" => "<!-- symphony-completion:pr=57 -->"}}
    refute_received {:request, _, "/repos/octo/repo/issues/44", _}
  end

  test "an unrelated merged PR and a closed issue cannot pass the gate" do
    responses = %{
      "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
      "/repos/octo/repo/issues/42/timeline" => []
    }

    unrelated = AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, completion_opts(responses))
    assert %{"outcome" => "unrelated_pr"} = Jason.decode!(unrelated["output"])

    closed =
      AgentTool.execute(
        "github_complete_issue",
        %{},
        completion_opts(%{
          "/repos/octo/repo/issues/42" => %{"state" => "closed", "number" => 42}
        })
      )

    assert %{"outcome" => "out_of_band_closure"} = Jason.decode!(closed["output"])
    refute_received {:request, "PATCH", _, _}
  end

  test "a PR first referenced after its merge cannot complete an issue" do
    reference = Map.put(cross_reference(57), "created_at", "2026-01-04T00:00:00Z")

    response =
      AgentTool.execute(
        "github_complete_issue",
        %{"pr_number" => 57},
        completion_opts(%{
          "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
          "/repos/octo/repo/issues/42/timeline" => [reference],
          "/repos/octo/repo" => %{"default_branch" => "main"},
          "/repos/octo/repo/pulls/57" => pr(57, "closed", true)
        })
      )

    assert %{"outcome" => "unrelated_pr"} = Jason.decode!(response["output"])
    refute_received {:request, "POST", _, _}
    refute_received {:request, "PATCH", _, _}
  end

  test "the six reported pre-closure shapes all remain open" do
    for {issue_number, pr_number} <- [{116, 122}, {117, 123}, {118, 124}, {119, nil}, {120, nil}, {121, nil}] do
      issue = %Issue{id: Integer.to_string(issue_number), identifier: "GH-#{issue_number}", state: "open", url: "https://github.com/octo/repo/issues/#{issue_number}"}
      timeline = if pr_number, do: [cross_reference(pr_number)], else: []

      response =
        AgentTool.execute("github_complete_issue", %{},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: issue,
          github_client: fn method, path, _params, _body, _opts ->
            send(self(), {:incident_request, method, path})

            body =
              cond do
                path == "/repos/octo/repo/issues/#{issue_number}" -> %{"state" => "open", "number" => issue_number}
                path == "/repos/octo/repo/issues/#{issue_number}/timeline" -> timeline
                path == "/repos/octo/repo" -> %{"default_branch" => "main"}
                path == "/repos/octo/repo/pulls/#{pr_number}" -> pr(pr_number, "open", false)
              end

            {:ok, %{status: 200, body: body}}
          end
        )

      expected = if pr_number, do: "open_pr", else: "no_pr"
      assert %{"outcome" => ^expected} = Jason.decode!(response["output"])
    end

    refute_received {:incident_request, "PATCH", _}
    refute_received {:incident_request, "POST", _}
  end

  test "a wrong target branch or multiple associated PRs cannot close the issue" do
    base = %{
      "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
      "/repos/octo/repo/issues/42/timeline" => [cross_reference(57)],
      "/repos/octo/repo" => %{"default_branch" => "main"},
      "/repos/octo/repo/pulls/57" => put_in(pr(57, "closed", true), ["base", "ref"], "release")
    }

    wrong_base = AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, completion_opts(base))
    assert %{"outcome" => "wrong_base"} = Jason.decode!(wrong_base["output"])

    ambiguous = AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, completion_opts(Map.put(base, "/repos/octo/repo/issues/42/timeline", [cross_reference(57), cross_reference(58)])))
    assert %{"outcome" => "ambiguous_pr"} = Jason.decode!(ambiguous["output"])
    refute_received {:request, "PATCH", _, _}
  end

  test "a failed successor label confirmation leaves the current issue open" do
    response =
      AgentTool.execute(
        "github_complete_issue",
        %{"pr_number" => 57},
        completion_opts(%{
          "/repos/octo/repo/issues/42" => %{"state" => "open", "number" => 42},
          "/repos/octo/repo/issues/42/timeline" => [cross_reference(57)],
          "/repos/octo/repo" => %{"default_branch" => "main"},
          "/repos/octo/repo/pulls/57" => pr(57, "closed", true),
          "/repos/octo/repo/issues/43" => %{"state" => "open", "number" => 43, "labels" => []},
          "/repos/octo/repo/issues/43/labels" => []
        })
      )

    refute response["success"]
    assert %{"outcome" => "transient_error"} = Jason.decode!(response["output"])
    assert_received {:request, "POST", "/repos/octo/repo/issues/43/labels", %{"labels" => ["agent-ready"]}}
    refute_received {:request, "PATCH", "/repos/octo/repo/issues/42", _}
  end

  test "a lost close receipt recovers after restart without repeating the close or handoff" do
    {:ok, state} =
      Agent.start(fn ->
        %{current: "open", successor_labels: [], marker: false, intent: false, fail_receipt: true, requests: []}
      end)

    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    test_pid = self()

    client = fn method, path, _params, body, _opts ->
      send(test_pid, {:request, method, path, body})

      Agent.get_and_update(state, fn current ->
        updated = %{current | requests: [{method, path} | current.requests]}

        result =
          case {method, path} do
            {"GET", "/repos/octo/repo/issues/42"} ->
              issue_response(updated.current)

            {"GET", "/repos/octo/repo/issues/42/timeline"} ->
              [cross_reference(57)]

            {"GET", "/repos/octo/repo"} ->
              %{"default_branch" => "main"}

            {"GET", "/repos/octo/repo/pulls/57"} ->
              pr(57, "closed", true)

            {"GET", "/repos/octo/repo/issues/43"} ->
              %{"state" => "open", "number" => 43, "labels" => updated.successor_labels}

            {"POST", "/repos/octo/repo/issues/43/labels"} ->
              []

            {"GET", "/repos/octo/repo/issues/42/comments"} ->
              if(updated.intent, do: [valid_intent()], else: []) ++ if updated.marker, do: [valid_marker()], else: []

            {"POST", "/repos/octo/repo/issues/42/comments"} ->
              %{}

            {"PATCH", "/repos/octo/repo/issues/42"} ->
              issue_response("closed")
          end

        failed_receipt? =
          method == "POST" and path == "/repos/octo/repo/issues/42/comments" and
            body["body"] == "<!-- symphony-completion:pr=57 -->" and updated.fail_receipt

        changed =
          case {method, path} do
            {"POST", "/repos/octo/repo/issues/43/labels"} ->
              %{updated | successor_labels: [%{"name" => "agent-ready"}]}

            {"POST", "/repos/octo/repo/issues/42/comments"} ->
              cond do
                body["body"] == "<!-- symphony-close-intent:pr=57 -->" -> %{updated | intent: true}
                failed_receipt? -> %{updated | fail_receipt: false}
                true -> %{updated | marker: true}
              end

            {"PATCH", "/repos/octo/repo/issues/42"} ->
              %{updated | current: "closed"}

            _ ->
              updated
          end

        response = if failed_receipt?, do: {:error, :timeout}, else: {:ok, %{status: 200, body: result}}
        {response, changed}
      end)
    end

    opts = [completion_policy: "merged_pr", tracker_settings: @settings, issue: @issue, github_client: client]
    assert AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, opts)["success"]
    refute Agent.get(state, & &1.marker)
    assert :ok = Completion.audit_closed(@issue, @settings, client)
    assert Agent.get(state, & &1.marker)
    assert AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, opts)["success"]

    requests = Agent.get(state, & &1.requests)

    assert Enum.find_index(requests, &(&1 == {"POST", "/repos/octo/repo/issues/42/comments"})) <
             Enum.find_index(requests, &(&1 == {"PATCH", "/repos/octo/repo/issues/42"}))

    assert Enum.count(requests, &(&1 == {"POST", "/repos/octo/repo/issues/43/labels"})) == 1
    assert Enum.count(requests, &(&1 == {"POST", "/repos/octo/repo/issues/42/comments"})) == 3
    assert Enum.count(requests, &(&1 == {"PATCH", "/repos/octo/repo/issues/42"})) == 1
    refute Enum.any?(requests, fn {_method, path} -> String.contains?(path, "/issues/44") end)
  end

  test "a timed-out close response recovers from GitHub's confirmed closed state" do
    {:ok, state} = Agent.start(fn -> %{closed: false, comments: [], close_calls: 0} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)

    client = fn method, path, _params, body, _opts ->
      case {method, path} do
        {"GET", "/repos/octo/repo/issues/42"} ->
          issue_state = if Agent.get(state, & &1.closed), do: "closed", else: "open"
          response(issue_response(issue_state))

        {"GET", "/repos/octo/repo/issues/42/timeline"} ->
          response([cross_reference(57)])

        {"GET", "/repos/octo/repo"} ->
          response(%{"default_branch" => "main"})

        {"GET", "/repos/octo/repo/pulls/57"} ->
          response(pr(57, "closed", true))

        {"GET", "/repos/octo/repo/issues/43"} ->
          {:ok, %{status: 404, body: %{}}}

        {"GET", "/repos/octo/repo/issues/42/comments"} ->
          response(Agent.get(state, & &1.comments))

        {"POST", "/repos/octo/repo/issues/42/comments"} ->
          comment = if body["body"] == "<!-- symphony-close-intent:pr=57 -->", do: valid_intent(), else: valid_marker()
          Agent.update(state, &%{&1 | comments: [comment | &1.comments]})
          response(comment)

        {"PATCH", "/repos/octo/repo/issues/42"} ->
          Agent.update(state, &%{&1 | closed: true, close_calls: &1.close_calls + 1})
          {:error, :timeout}
      end
    end

    opts = [completion_policy: "merged_pr", tracker_settings: @settings, issue: @issue, github_client: client]
    first = AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, opts)
    refute first["success"]
    assert %{"outcome" => "transient_error"} = Jason.decode!(first["output"])

    assert :ok = Completion.audit_closed(@issue, @settings, client)
    assert Agent.get(state, & &1.close_calls) == 1
    assert Agent.get(state, &Enum.any?(&1.comments, fn comment -> comment["body"] == valid_marker()["body"] end))
  end

  test "raw issue and label writes are refused under merged-PR policy" do
    for {method, path, body} <- [
          {"PATCH", "/repos/octo/repo/issues/42", %{"state" => "closed"}},
          {"POST", "/repos/octo/repo/issues/43/labels", %{"labels" => ["agent-ready"]}},
          {"DELETE", "/repos/octo/repo/issues/42/labels/agent-ready", nil}
        ] do
      response =
        AgentTool.execute("github_api", %{"method" => method, "path" => path, "body" => body},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn _, _, _, _, _ -> flunk("denied mutation reached GitHub") end
        )

      refute response["success"]
    end

    missing_binding =
      AgentTool.execute("github_api", %{"method" => "POST", "path" => "/repos/octo/repo/pulls", "body" => %{}},
        completion_policy: "merged_pr",
        issue: @issue,
        github_client: fn _, _, _, _, _ -> flunk("unbound PR write reached GitHub") end
      )

    refute missing_binding["success"]
  end

  test "PR publication and merge remain available through the bound GitHub tool" do
    assert Enum.map(AgentTool.tool_specs("merged_pr"), & &1["name"]) == [
             "github_api",
             "github_complete_issue",
             "github_push_branch"
           ]

    for {method, path, body} <- [
          {"POST", "/repos/octo/repo/pulls", %{"title" => "Fix", "head" => "feature-42", "base" => "main"}},
          {"PATCH", "/repos/octo/repo/pulls/57", %{"title" => "Updated"}},
          {"PUT", "/repos/octo/repo/pulls/57/merge", %{"merge_method" => "squash"}}
        ] do
      response =
        AgentTool.execute("github_api", %{"method" => method, "path" => path, "body" => body},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn request_method, request_path, _params, request_body, _opts ->
            case {request_method, request_path} do
              {"GET", "/repos/octo/repo/issues/42/timeline"} ->
                {:ok, %{status: 200, body: [cross_reference(57)]}}

              {^method, ^path} ->
                assert request_body == body
                {:ok, %{status: 200, body: %{}}}
            end
          end
        )

      assert response["success"]
    end

    unrelated_merge =
      AgentTool.execute("github_api", %{"method" => "PUT", "path" => "/repos/octo/repo/pulls/58/merge", "body" => %{}},
        completion_policy: "merged_pr",
        tracker_settings: @settings,
        issue: @issue,
        github_client: fn
          "GET", "/repos/octo/repo/issues/42/timeline", _, _, _ -> {:ok, %{status: 200, body: [cross_reference(57)]}}
          _, _, _, _, _ -> flunk("unrelated PR merge reached GitHub")
        end
      )

    refute unrelated_merge["success"]

    for {method, path} <- [
          {"PATCH", "/repos/octo/repo/pulls/0"},
          {"PUT", "/repos/octo/repo/pulls/57/comments"},
          {"PUT", "/repos/octo/repo/pulls/not-a-number/merge"}
        ] do
      denied =
        AgentTool.execute("github_api", %{"method" => method, "path" => path, "body" => %{}},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn _, _, _, _, _ -> flunk("invalid PR write reached GitHub") end
        )

      refute denied["success"]
    end

    timeout =
      AgentTool.execute("github_api", %{"method" => "PUT", "path" => "/repos/octo/repo/pulls/57/merge", "body" => %{}},
        completion_policy: "merged_pr",
        tracker_settings: @settings,
        issue: @issue,
        github_client: fn "GET", "/repos/octo/repo/issues/42/timeline", _, _, _ -> {:error, :timeout} end
      )

    refute timeout["success"]

    for body <- ["<!-- symphony-completion:pr=57 -->", "<!-- symphony-close-intent:pr=57 -->"] do
      marker =
        AgentTool.execute(
          "github_api",
          %{
            "method" => "POST",
            "path" => "/repos/octo/repo/issues/42/comments",
            "body" => %{"body" => body}
          },
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn _, _, _, _, _ -> flunk("agent cannot forge completion records") end
        )

      refute marker["success"]
    end

    read =
      AgentTool.execute("github_api", %{"method" => "GET", "path" => "/repos/octo/repo/issues/42"},
        completion_policy: "merged_pr",
        tracker_settings: @settings,
        issue: @issue,
        github_client: fn "GET", _, %{}, nil, _ -> {:ok, %{status: 200, body: %{}}} end
      )

    assert read["success"]

    refute AgentTool.execute("github_complete_issue", %{}, [])["success"]
    refute AgentTool.execute("github_push_branch", %{}, [])["success"]
    refute AgentTool.execute("github_push_branch", %{}, completion_policy: "merged_pr")["success"]
  end

  test "terminal audit reports a close that lacks Symphony's completion marker" do
    client = fn "GET", path, _params, nil, _opts ->
      body = if String.ends_with?(path, "/comments"), do: [%{"body" => "local tests passed"}], else: issue_response("closed")
      {:ok, %{status: 200, body: body}}
    end

    assert {:error, :out_of_band_closure} = Completion.audit_closed(@issue, @settings, client)

    marked = fn "GET", path, _params, nil, _opts ->
      body = if String.ends_with?(path, "/comments"), do: [valid_intent(), valid_marker()], else: issue_response("closed")
      {:ok, %{status: 200, body: body}}
    end

    assert :ok = Completion.audit_closed(@issue, @settings, marked)

    wrong_actor = fn "GET", path, _params, nil, _opts ->
      body =
        if String.ends_with?(path, "/comments") do
          [%{valid_intent() | "user" => %{"id" => 8}}, valid_marker()]
        else
          issue_response("closed")
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:error, :out_of_band_closure} = Completion.audit_closed(@issue, @settings, wrong_actor)

    early_marker = fn "GET", path, _params, nil, _opts ->
      body =
        if String.ends_with?(path, "/comments") do
          [valid_intent(), %{valid_marker() | "created_at" => "2026-01-03T00:00:00Z"}]
        else
          issue_response("closed")
        end

      {:ok, %{status: 200, body: body}}
    end

    assert {:error, {:recovery_failed, {:error, :invalid_timeline_response}}} =
             Completion.audit_closed(@issue, @settings, early_marker)
  end

  defp completion_opts(responses) do
    test_pid = self()
    {:ok, comments} = Agent.start(fn -> Map.get(responses, "/repos/octo/repo/issues/42/comments", []) end)
    on_exit(fn -> if Process.alive?(comments), do: Agent.stop(comments) end)

    [
      completion_policy: "merged_pr",
      tracker_settings: @settings,
      issue: @issue,
      github_client: fn method, path, _params, body, _opts ->
        send(test_pid, {:request, method, path, body})

        case {method, path} do
          {"PATCH", "/repos/octo/repo/issues/42"} ->
            {:ok, %{status: 200, body: issue_response("closed")}}

          {"POST", "/repos/octo/repo/issues/42/comments"} ->
            comment = if body["body"] == "<!-- symphony-close-intent:pr=57 -->", do: valid_intent(), else: valid_marker()
            Agent.update(comments, &[comment | &1])
            {:ok, %{status: 201, body: comment}}

          {"GET", "/repos/octo/repo/issues/42/comments"} ->
            {:ok, %{status: 200, body: Agent.get(comments, & &1)}}

          _ ->
            {:ok, %{status: 200, body: Map.fetch!(responses, path)}}
        end
      end
    ]
  end

  defp cross_reference(number) do
    %{
      "event" => "cross-referenced",
      "created_at" => "2026-01-02T00:00:00Z",
      "source" => %{
        "issue" => %{
          "number" => number,
          "html_url" => "https://github.com/octo/repo/pull/#{number}",
          "pull_request" => %{"url" => "https://api.github.com/repos/octo/repo/pulls/#{number}"}
        }
      }
    }
  end

  defp pr(number, state, merged) do
    %{
      "number" => number,
      "state" => state,
      "merged" => merged,
      "merged_at" => if(merged, do: "2026-01-03T00:00:00Z", else: nil),
      "base" => %{"ref" => "main", "repo" => %{"full_name" => "octo/repo"}}
    }
  end

  defp issue_response("closed"),
    do: %{"state" => "closed", "number" => 42, "closed_at" => "2026-01-04T00:00:00Z", "closed_by" => %{"id" => 7}}

  defp issue_response(state), do: %{"state" => state, "number" => 42}

  defp valid_marker, do: %{"body" => "<!-- symphony-completion:pr=57 -->", "created_at" => "2026-01-04T00:00:01Z"}
  defp valid_intent, do: %{"body" => "<!-- symphony-close-intent:pr=57 -->", "created_at" => "2026-01-03T23:59:59Z", "user" => %{"id" => 7}}

  defp response(body), do: {:ok, %{status: 200, body: body}}
end
