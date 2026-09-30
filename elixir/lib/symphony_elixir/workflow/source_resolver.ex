defmodule SymphonyElixir.Workflow.SourceResolver do
  @moduledoc false

  alias SymphonyElixir.PathSafety

  @composition_keys ["include", "prompt_file"]

  @spec resolve(Path.t()) :: {:ok, SymphonyElixir.Workflow.loaded_workflow()} | {:error, term()}
  def resolve(entry_path) when is_binary(entry_path) do
    entry_path = Path.expand(entry_path)

    with {:ok, entry_content} <- read_entry(entry_path),
         {:ok, entry_config, inline_prompt} <- parse_workflow(entry_content),
         {:ok, included_config, included_paths} <- load_includes(entry_config, entry_path),
         {:ok, prompt, prompt_path} <- load_prompt(entry_config, inline_prompt, entry_path) do
      {:ok,
       %{
         config: deep_merge(included_config, Map.drop(entry_config, @composition_keys)),
         prompt: prompt,
         prompt_template: prompt,
         source_paths: [entry_path | included_paths ++ List.wrap(prompt_path)]
       }}
    end
  end

  defp read_entry(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:missing_workflow_file, path, reason}}
    end
  end

  defp load_includes(entry_config, entry_path) do
    entry_config
    |> Map.get("include", [])
    |> load_library_paths(entry_path)
  end

  defp load_library_paths([], _entry_path), do: {:ok, %{}, []}

  defp load_library_paths(include_paths, entry_path) do
    library_root = Path.expand("../workflow-libraries", Path.dirname(entry_path))

    with :ok <- validate_include_paths(include_paths, entry_path),
         :ok <- ensure_library_root(library_root, entry_path, "include") do
      load_include_paths(include_paths, entry_path, library_root, %{}, [], [])
    end
  end

  defp validate_include_paths(paths, _entry_path) when is_list(paths), do: :ok

  defp validate_include_paths(_paths, entry_path) do
    {:error, {:invalid_workflow_include, entry_path, "include", :must_be_a_list}}
  end

  defp load_include_paths([], _referrer, _library_root, config, paths, _ancestry),
    do: {:ok, config, paths}

  defp load_include_paths([include_path | remaining], referrer, library_root, config, paths, ancestry) do
    with {:ok, resolved_path} <- resolve_library_path(include_path, referrer, library_root),
         :ok <- reject_include_cycle(resolved_path, ancestry, referrer, include_path),
         {:ok, content} <- read_library(resolved_path, referrer, include_path),
         {:ok, library_config} <- parse_library(content, resolved_path, referrer, include_path),
         :ok <- reject_library_prompt_file(library_config, resolved_path, referrer, include_path),
         {:ok, nested_config, nested_paths} <-
           load_nested_includes(library_config, resolved_path, library_root, [resolved_path | ancestry]),
         merged_config <- deep_merge(config, deep_merge(nested_config, Map.drop(library_config, @composition_keys))) do
      load_include_paths(
        remaining,
        referrer,
        library_root,
        merged_config,
        paths ++ nested_paths ++ [resolved_path],
        ancestry
      )
    end
  end

  defp load_nested_includes(library_config, library_path, library_root, ancestry) do
    nested_paths = Map.get(library_config, "include", [])

    with :ok <- validate_include_paths(nested_paths, library_path) do
      load_include_paths(nested_paths, library_path, library_root, %{}, [], ancestry)
    end
  end

  defp reject_include_cycle(resolved_path, ancestry, referrer, include_path) do
    if resolved_path in ancestry do
      {:error, {:workflow_include_cycle, referrer, include_path}}
    else
      :ok
    end
  end

  defp reject_library_prompt_file(library_config, library_path, referrer, include_path) do
    if Map.has_key?(library_config, "prompt_file") do
      reason = {:workflow_library_prompt_file_not_allowed, library_path}
      {:error, {:invalid_workflow_include, referrer, include_path, reason}}
    else
      :ok
    end
  end

  defp resolve_library_path(include_path, referrer, library_root) when is_binary(include_path) do
    cond do
      Path.type(include_path) == :absolute ->
        {:error, {:invalid_workflow_include, referrer, include_path, :must_be_relative}}

      Path.extname(include_path) in [".yml", ".yaml"] ->
        candidate_path = Path.expand(include_path, Path.dirname(referrer))

        with :ok <- ensure_library_source_is_not_symlink(candidate_path),
             {:ok, real_library_root} <- realpath(library_root),
             {:ok, real_candidate_path} <- realpath(candidate_path),
             :ok <- ensure_within_library_root(real_candidate_path, real_library_root) do
          {:ok, real_candidate_path}
        else
          {:error, reason} -> {:error, {:invalid_workflow_include, referrer, include_path, reason}}
        end

      true ->
        {:error, {:invalid_workflow_include, referrer, include_path, :must_reference_yaml}}
    end
  end

  defp resolve_library_path(include_path, referrer, _library_root) do
    {:error, {:invalid_workflow_include, referrer, include_path, :must_reference_yaml}}
  end

  defp ensure_within_library_root(path, library_root) do
    relative = Path.relative_to(path, library_root)

    if relative == path or relative == ".." or String.starts_with?(relative, "../") do
      {:error, :outside_workflow_library_root}
    else
      :ok
    end
  end

  defp read_library(path, referrer, include_path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, {:invalid_workflow_include, referrer, include_path, reason}}
    end
  end

  defp load_prompt(entry_config, inline_prompt, entry_path) do
    case Map.get(entry_config, "prompt_file") do
      nil ->
        {:ok, inline_prompt, nil}

      prompt_path when is_binary(prompt_path) ->
        if String.trim(inline_prompt) == "" do
          load_prompt_file(prompt_path, entry_path)
        else
          {:error, {:invalid_workflow_prompt_file, entry_path}}
        end

      _ ->
        {:error, {:invalid_workflow_prompt_file, entry_path}}
    end
  end

  defp load_prompt_file(prompt_path, entry_path) do
    if Path.extname(prompt_path) == ".md" do
      library_root = Path.expand("../workflow-libraries", Path.dirname(entry_path))

      with :ok <- ensure_library_root(library_root, entry_path, prompt_path),
           {:ok, resolved_path} <- resolve_prompt_path(prompt_path, entry_path, library_root),
           {:ok, content} <- File.read(resolved_path) do
        {:ok, String.trim(content), resolved_path}
      else
        {:error, reason} -> {:error, {:invalid_workflow_prompt_file, entry_path, prompt_path, reason}}
      end
    else
      {:error, {:invalid_workflow_prompt_file, entry_path, prompt_path, :must_reference_markdown}}
    end
  end

  defp resolve_prompt_path(prompt_path, referrer, library_root) do
    if Path.type(prompt_path) == :absolute do
      {:error, :must_be_relative}
    else
      candidate_path = Path.expand(prompt_path, Path.dirname(referrer))

      with :ok <- ensure_library_source_is_not_symlink(candidate_path),
           {:ok, real_library_root} <- realpath(library_root),
           {:ok, real_candidate_path} <- realpath(candidate_path),
           :ok <- ensure_within_library_root(real_candidate_path, real_library_root) do
        {:ok, real_candidate_path}
      end
    end
  end

  defp parse_library(content, path, referrer, include_path) do
    case YamlElixir.read_from_string(content) do
      {:ok, decoded} when is_map(decoded) ->
        {:ok, decoded}

      {:ok, _} ->
        {:error, {:invalid_workflow_include, referrer, include_path, {:workflow_library_not_a_map, path}}}

      {:error, reason} ->
        {:error, {:invalid_workflow_include, referrer, include_path, {:workflow_library_parse_error, path, reason}}}
    end
  end

  defp parse_workflow(content) do
    {front_matter_lines, prompt_lines} = split_front_matter(content)

    with {:ok, config} <- parse_front_matter(front_matter_lines) do
      {:ok, config, prompt_lines |> Enum.join("\n") |> String.trim()}
    end
  end

  defp split_front_matter(content) do
    case String.split(content, ~r/\R/, trim: false) do
      ["---" | tail] ->
        {front_matter, rest} = Enum.split_while(tail, &(&1 != "---"))
        if rest == [], do: {front_matter, []}, else: {front_matter, tl(rest)}

      lines ->
        {[], lines}
    end
  end

  defp parse_front_matter(lines) do
    yaml = Enum.join(lines, "\n")

    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
        {:ok, _} -> {:error, :workflow_front_matter_not_a_map}
        {:error, reason} -> {:error, {:workflow_parse_error, reason}}
      end
    end
  end

  defp deep_merge(left, right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp realpath(path) do
    PathSafety.canonicalize(path)
  end

  defp ensure_library_root(library_root, referrer, include_path) do
    case File.lstat(library_root) do
      {:ok, %File.Stat{type: :directory}} ->
        :ok

      {:ok, %File.Stat{type: :symlink}} ->
        {:error, {:invalid_workflow_include, referrer, include_path, :workflow_library_root_must_not_be_symlink}}

      {:ok, _stat} ->
        {:error, {:invalid_workflow_include, referrer, include_path, :workflow_library_root_must_be_directory}}

      {:error, reason} ->
        {:error, {:invalid_workflow_include, referrer, include_path, reason}}
    end
  end

  defp ensure_library_source_is_not_symlink(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:error, :workflow_library_source_must_not_be_symlink}
      {:ok, _stat} -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
