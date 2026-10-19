defmodule SymphonyElixir.GitHub.AgentTool do
  @moduledoc """
  Provider-native GitHub REST tool exposed to Codex app-server turns.
  """

  alias SymphonyElixir.GitHub.{Client, Completion, Push}

  @github_api_tool "github_api"
  @completion_tool "github_complete_issue"
  @push_tool "github_push_branch"
  @allowed_methods ["GET", "POST", "PATCH", "PUT", "DELETE"]
  @github_api_description """
  Execute a GitHub REST API request using Symphony's configured auth.
  """
  @github_api_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["method", "path"],
    "properties" => %{
      "method" => %{
        "type" => "string",
        "enum" => @allowed_methods,
        "description" => "GitHub REST method."
      },
      "path" => %{
        "type" => "string",
        "description" => "GitHub REST path such as /repos/owner/repo/issues/1/comments."
      },
      "params" => %{
        "type" => ["object", "null"],
        "description" => "Optional query parameters.",
        "additionalProperties" => true
      },
      "body" => %{
        "type" => ["object", "array", "null"],
        "description" => "Optional JSON request body."
      }
    }
  }
  @completion_input_schema %{
    "type" => "object",
    "additionalProperties" => false,
    "properties" => %{
      "pr_number" => %{"type" => "integer", "minimum" => 1, "description" => "Actual associated PR number, if known."}
    }
  }

  @spec execute(String.t() | nil, term(), keyword()) :: map()
  def execute(tool, arguments, opts) do
    case tool do
      @github_api_tool ->
        execute_github_api(arguments, opts)

      @completion_tool ->
        if opts[:completion_policy] == "merged_pr" do
          execute_completion(arguments, opts)
        else
          unsupported_tool_response(tool)
        end

      @push_tool ->
        if opts[:completion_policy] == "merged_pr" do
          execute_push(arguments, opts)
        else
          unsupported_tool_response(tool)
        end

      other ->
        unsupported_tool_response(other)
    end
  end

  @spec tool_specs() :: [map()]
  def tool_specs do
    [
      %{
        "name" => @github_api_tool,
        "description" => @github_api_description,
        "inputSchema" => @github_api_input_schema
      }
    ]
  end

  @spec tool_specs(String.t() | nil) :: [map()]
  def tool_specs("merged_pr") do
    tool_specs() ++
      [
        %{
          "name" => @completion_tool,
          "description" => "Ask Symphony to verify a merged PR, release the immediate successor, and close the current issue.",
          "inputSchema" => @completion_input_schema
        },
        %{
          "name" => @push_tool,
          "description" => "Push the current feature branch from this issue workspace to its verified GitHub origin.",
          "inputSchema" => %{"type" => "object", "additionalProperties" => false, "properties" => %{}}
        }
      ]
  end

  def tool_specs(_policy), do: tool_specs()

  defp execute_github_api(arguments, opts) do
    github_client = Keyword.get(opts, :github_client, &Client.request/5)
    client_opts = Keyword.take(opts, [:tracker_settings])

    with {:ok, method, path, params, body} <- normalize_arguments(arguments),
         :ok <- authorize_api_request(method, path, body, opts),
         {:ok, %{status: status, body: response_body}} <-
           github_client.(method, path, params, body, client_opts),
         true <- is_integer(status) do
      rest_response(status, response_body)
    else
      {:error, reason} -> failure_response(tool_error_payload(reason))
      _ -> failure_response(tool_error_payload(:github_unknown_payload))
    end
  end

  defp execute_completion(arguments, opts) do
    client = Keyword.get(opts, :github_client, &Client.request/5)

    case Completion.run(arguments, Keyword.fetch(opts, :issue), Keyword.fetch(opts, :tracker_settings), client) do
      {:ok, %{"outcome" => "completed"} = payload} -> dynamic_tool_response(true, encode_payload(payload))
      {:ok, payload} -> failure_response(payload)
      {:error, reason} -> failure_response(%{"outcome" => "transient_error", "reason" => inspect(reason)})
    end
  end

  defp execute_push(arguments, opts) do
    case Push.run(arguments, opts) do
      {:ok, payload} -> dynamic_tool_response(true, encode_payload(payload))
      {:error, reason} -> failure_response(%{"outcome" => "push_failed", "reason" => inspect(reason)})
    end
  end

  defp authorize_api_request(method, path, body, opts) do
    if opts[:completion_policy] == "merged_pr" do
      authorize_guarded_request(method, path, body, opts)
    else
      :ok
    end
  end

  defp authorize_guarded_request("GET", _path, _body, _opts), do: :ok

  defp authorize_guarded_request("POST", path, body, opts) do
    if permitted_pr_write?("POST", path, opts), do: :ok, else: authorize_issue_comment(path, body, opts)
  end

  defp authorize_guarded_request("PATCH", path, _body, opts) do
    if permitted_pr_write?("PATCH", path, opts), do: :ok, else: {:error, :completion_policy_denies_issue_write}
  end

  defp authorize_guarded_request("PUT", path, _body, opts) do
    if permitted_pr_write?("PUT", path, opts), do: :ok, else: {:error, :completion_policy_denies_issue_write}
  end

  defp authorize_guarded_request(_method, _path, _body, _opts), do: {:error, :completion_policy_denies_issue_write}

  defp authorize_issue_comment(path, body, opts) do
    with %{id: id} <- opts[:issue],
         %{provider: %{"repo" => repo}} <- opts[:tracker_settings],
         true <- path == "/repos/#{repo}/issues/#{id}/comments",
         %{"body" => text} when is_binary(text) <- body,
         false <- String.contains?(text, "<!-- symphony-completion:") do
      :ok
    else
      _ -> {:error, :completion_policy_denies_issue_write}
    end
  end

  defp permitted_pr_write?(method, path, opts) do
    case opts[:tracker_settings] do
      %{provider: %{"repo" => repo}} ->
        case {method, String.replace_prefix(path, "/repos/#{repo}/", "")} do
          {"POST", "pulls"} -> true
          {"PATCH", suffix} -> String.match?(suffix, ~r/^pulls\/[1-9][0-9]*$/)
          {"PUT", suffix} -> String.match?(suffix, ~r/^pulls\/[1-9][0-9]*\/merge$/)
          _ -> false
        end

      _ ->
        false
    end
  end

  defp normalize_arguments(arguments) when is_map(arguments) do
    with {:ok, method} <- normalize_method(Map.get(arguments, "method")),
         {:ok, path} <- normalize_path(Map.get(arguments, "path")),
         {:ok, params} <- normalize_params(Map.get(arguments, "params")),
         {:ok, body} <- normalize_body(Map.get(arguments, "body")) do
      {:ok, method, path, params, body}
    end
  end

  defp normalize_arguments(_arguments), do: {:error, :invalid_arguments}

  defp normalize_method(method) when is_binary(method) do
    normalized = method |> String.trim() |> String.upcase()
    if normalized in @allowed_methods, do: {:ok, normalized}, else: {:error, :invalid_method}
  end

  defp normalize_method(_method), do: {:error, :invalid_method}

  defp normalize_path(path) when is_binary(path) do
    trimmed = String.trim(path)

    if String.starts_with?(trimmed, "/") and not String.contains?(trimmed, ["://", "\n", "\r", <<0>>]) do
      {:ok, trimmed}
    else
      {:error, :invalid_path}
    end
  end

  defp normalize_path(_path), do: {:error, :invalid_path}

  defp normalize_params(nil), do: {:ok, %{}}
  defp normalize_params(params) when is_map(params), do: {:ok, params}
  defp normalize_params(_params), do: {:error, :invalid_params}

  defp normalize_body(nil), do: {:ok, nil}
  defp normalize_body(body) when is_map(body) or is_list(body), do: {:ok, body}
  defp normalize_body(_body), do: {:error, :invalid_body}

  defp rest_response(status, body) do
    dynamic_tool_response(status in 200..299, encode_payload(%{"status" => status, "body" => body}))
  end

  defp failure_response(payload), do: dynamic_tool_response(false, encode_payload(payload))

  defp dynamic_tool_response(success, output) do
    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end

  defp encode_payload(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, output} -> output
      {:error, _reason} -> inspect(payload)
    end
  end

  defp unsupported_tool_response(tool) do
    failure_response(%{
      "error" => %{
        "message" => "Unsupported dynamic tool: #{inspect(tool)}.",
        "supportedTools" => supported_tool_names()
      }
    })
  end

  defp tool_error_payload(:invalid_arguments) do
    %{"error" => %{"message" => "`github_api` expects an object with `method` and `path`."}}
  end

  defp tool_error_payload(:invalid_method) do
    %{"error" => %{"message" => "`github_api.method` must be GET, POST, PATCH, PUT, or DELETE."}}
  end

  defp tool_error_payload(:invalid_path) do
    %{"error" => %{"message" => "`github_api.path` must be a relative GitHub REST path."}}
  end

  defp tool_error_payload(:invalid_params) do
    %{"error" => %{"message" => "`github_api.params` must be a JSON object when provided."}}
  end

  defp tool_error_payload(:invalid_body) do
    %{"error" => %{"message" => "`github_api.body` must be a JSON object, array, or null."}}
  end

  defp tool_error_payload(:missing_github_token) do
    %{
      "error" => %{
        "message" => "Symphony is missing GitHub auth. Set `tracker.provider.token` in `WORKFLOW.md` or export `GITHUB_TOKEN`."
      }
    }
  end

  defp tool_error_payload({:github_api_request, reason}) do
    %{
      "error" => %{
        "message" => "GitHub API request failed before receiving a successful response.",
        "reason" => inspect(reason)
      }
    }
  end

  defp tool_error_payload(reason) do
    %{"error" => %{"message" => "GitHub API tool execution failed.", "reason" => inspect(reason)}}
  end

  defp supported_tool_names, do: Enum.map(tool_specs(), & &1["name"])
end
