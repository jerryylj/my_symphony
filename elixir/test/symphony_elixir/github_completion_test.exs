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
    assert_received {:request, "POST", "/repos/octo/repo/issues/42/comments", %{"body" => "<!-- symphony-completion:pr=57 -->"}}
    assert_received {:request, "PATCH", "/repos/octo/repo/issues/42", %{"state" => "closed"}}
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

  test "handoff adds only the immediate successor label, then closes; retry does not duplicate it" do
    {:ok, state} = Agent.start_link(fn -> %{current: "open", successor_labels: [], marker: false, requests: []} end)
    on_exit(fn -> if Process.alive?(state), do: Agent.stop(state) end)
    test_pid = self()

    client = fn method, path, _params, body, _opts ->
      send(test_pid, {:request, method, path, body})

      Agent.get_and_update(state, fn current ->
        updated = %{current | requests: [{method, path} | current.requests]}

        result =
          case {method, path} do
            {"GET", "/repos/octo/repo/issues/42"} -> %{"state" => updated.current, "number" => 42}
            {"GET", "/repos/octo/repo/issues/42/timeline"} -> [cross_reference(57)]
            {"GET", "/repos/octo/repo"} -> %{"default_branch" => "main"}
            {"GET", "/repos/octo/repo/pulls/57"} -> pr(57, "closed", true)
            {"GET", "/repos/octo/repo/issues/43"} -> %{"state" => "open", "number" => 43, "labels" => updated.successor_labels}
            {"POST", "/repos/octo/repo/issues/43/labels"} -> []
            {"GET", "/repos/octo/repo/issues/42/comments"} -> if(updated.marker, do: [%{"body" => "<!-- symphony-completion:pr=57 -->"}], else: [])
            {"POST", "/repos/octo/repo/issues/42/comments"} -> %{}
            {"PATCH", "/repos/octo/repo/issues/42"} -> %{"state" => "closed"}
          end

        changed =
          case {method, path} do
            {"POST", "/repos/octo/repo/issues/43/labels"} -> %{updated | successor_labels: [%{"name" => "agent-ready"}]}
            {"POST", "/repos/octo/repo/issues/42/comments"} -> %{updated | marker: true}
            {"PATCH", "/repos/octo/repo/issues/42"} -> %{updated | current: "closed"}
            _ -> updated
          end

        {{:ok, %{status: 200, body: result}}, changed}
      end)
    end

    opts = [completion_policy: "merged_pr", tracker_settings: @settings, issue: @issue, github_client: client]
    assert AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, opts)["success"]
    assert AgentTool.execute("github_complete_issue", %{"pr_number" => 57}, opts)["success"]

    requests = Agent.get(state, & &1.requests)
    assert Enum.count(requests, &(&1 == {"POST", "/repos/octo/repo/issues/43/labels"})) == 1
    assert Enum.count(requests, &(&1 == {"POST", "/repos/octo/repo/issues/42/comments"})) == 1
    assert Enum.count(requests, &(&1 == {"PATCH", "/repos/octo/repo/issues/42"})) == 1
    refute Enum.any?(requests, fn {_method, path} -> String.contains?(path, "/issues/44") end)
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
  end

  test "PR publication and merge remain available through the bound GitHub tool" do
    assert Enum.map(AgentTool.tool_specs("merged_pr"), & &1["name"]) == [
             "github_api",
             "github_complete_issue",
             "github_push_branch"
           ]

    for {method, path, body} <- [
          {"POST", "/repos/octo/repo/pulls", %{"title" => "Fix", "head" => "feature-42", "base" => "main"}},
          {"PUT", "/repos/octo/repo/pulls/57/merge", %{"merge_method" => "squash"}}
        ] do
      response =
        AgentTool.execute("github_api", %{"method" => method, "path" => path, "body" => body},
          completion_policy: "merged_pr",
          tracker_settings: @settings,
          issue: @issue,
          github_client: fn ^method, ^path, %{}, ^body, _opts ->
            {:ok, %{status: 200, body: %{}}}
          end
        )

      assert response["success"]
    end

    marker =
      AgentTool.execute(
        "github_api",
        %{
          "method" => "POST",
          "path" => "/repos/octo/repo/issues/42/comments",
          "body" => %{"body" => "<!-- symphony-completion:pr=57 -->"}
        },
        completion_policy: "merged_pr",
        tracker_settings: @settings,
        issue: @issue,
        github_client: fn _, _, _, _, _ -> flunk("agent cannot forge completion marker") end
      )

    refute marker["success"]

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
    client = fn "GET", "/repos/octo/repo/issues/42/comments", _params, nil, _opts ->
      {:ok, %{status: 200, body: [%{"body" => "local tests passed"}]}}
    end

    assert {:error, :out_of_band_closure} = Completion.audit_closed(@issue, @settings, client)

    marked = fn "GET", "/repos/octo/repo/issues/42/comments", _params, nil, _opts ->
      {:ok, %{status: 200, body: [%{"body" => "<!-- symphony-completion:pr=57 -->"}]}}
    end

    assert :ok = Completion.audit_closed(@issue, @settings, marked)
  end

  defp completion_opts(responses) do
    test_pid = self()

    [
      completion_policy: "merged_pr",
      tracker_settings: @settings,
      issue: @issue,
      github_client: fn method, path, _params, body, _opts ->
        send(test_pid, {:request, method, path, body})

        case {method, path} do
          {"PATCH", "/repos/octo/repo/issues/42"} -> {:ok, %{status: 200, body: %{"state" => "closed"}}}
          {"POST", "/repos/octo/repo/issues/42/comments"} -> {:ok, %{status: 201, body: %{}}}
          {"GET", "/repos/octo/repo/issues/42/comments"} -> {:ok, %{status: 200, body: Map.get(responses, path, [])}}
          _ -> {:ok, %{status: 200, body: Map.fetch!(responses, path)}}
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
end
