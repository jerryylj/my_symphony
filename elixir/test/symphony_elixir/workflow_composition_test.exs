defmodule SymphonyElixir.WorkflowCompositionTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Workflow

  test "workflow entry resolves shared configuration and prompt libraries" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)

    File.write!(
      Path.join(library_root, "github-serial.yml"),
      """
      tracker:
        kind: github
        required_labels:
          - agent-ready
      agent:
        max_concurrent_agents: 1
        max_turns: 40
      """
    )

    File.write!(Path.join(library_root, "github-serial.md"), "Shared GitHub serial flow\n")

    File.write!(
      entry,
      """
      ---
      include:
        - ../workflow-libraries/github-serial.yml
      prompt_file: ../workflow-libraries/github-serial.md
      tracker:
        provider:
          repo: jerryylj/stock_manage
      agent:
        max_turns: 2
      ---
      """
    )

    assert {:ok, workflow} = Workflow.load(entry)
    assert workflow.prompt == "Shared GitHub serial flow"
    assert workflow.prompt_template == "Shared GitHub serial flow"

    assert workflow.config == %{
             "tracker" => %{
               "kind" => "github",
               "provider" => %{"repo" => "jerryylj/stock_manage"},
               "required_labels" => ["agent-ready"]
             },
             "agent" => %{"max_concurrent_agents" => 1, "max_turns" => 2}
           }

    assert workflow.source_paths |> Enum.map(&Path.basename/1) ==
             ["WORKFLOW.md", "github-serial.yml", "github-serial.md"]
  end

  test "workflow entry rejects a cycle in shared configuration libraries" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(Path.join(library_root, "first.yml"), "include:\n  - second.yml\n")
    File.write!(Path.join(library_root, "second.yml"), "include:\n  - first.yml\n")
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/first.yml\n---\n")

    assert {:error, {:workflow_include_cycle, referrer, "first.yml"}} = Workflow.load(entry)
    assert Path.basename(referrer) == "second.yml"
  end

  test "workflow entry rejects a prompt source declared by a shared configuration library" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)

    File.write!(
      Path.join(library_root, "github-serial.yml"),
      "prompt_file: github-serial.md\n"
    )

    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/github-serial.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/github-serial.yml", {:workflow_library_prompt_file_not_allowed, library_path}}} = Workflow.load(entry)
    assert Path.basename(library_path) == "github-serial.yml"
  end

  test "workflow entry reports its referrer when an included library is malformed" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    library_path = Path.join(library_root, "github-serial.yml")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(library_path, "tracker: [\n")
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/github-serial.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/github-serial.yml", {:workflow_library_parse_error, resolved_library_path, _reason}}} = Workflow.load(entry)

    assert Path.basename(resolved_library_path) == "github-serial.yml"
  end

  test "workflow entry reports a missing included library with its referrer and path" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/missing.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/missing.yml", :enoent}} =
             Workflow.load(entry)
  end

  test "workflow entry rejects a non-YAML library reference" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/github-serial.txt\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/github-serial.txt", :must_reference_yaml}} = Workflow.load(entry)
  end

  test "workflow entry merges nested libraries and replaces later lists and scalars" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)

    File.write!(
      Path.join(library_root, "defaults.yml"),
      """
      tracker:
        required_labels:
          - base-label
      agent:
        max_concurrent_agents: 1
        max_turns: 20
      """
    )

    File.write!(
      Path.join(library_root, "github-serial.yml"),
      """
      include:
        - defaults.yml
      tracker:
        required_labels:
          - agent-ready
      agent:
        max_turns: 40
      """
    )

    File.write!(
      entry,
      """
      ---
      include:
        - ../workflow-libraries/github-serial.yml
      agent:
        max_turns: 2
      ---
      """
    )

    assert {:ok, %{config: config}} = Workflow.load(entry)
    assert config["tracker"]["required_labels"] == ["agent-ready"]
    assert config["agent"] == %{"max_concurrent_agents" => 1, "max_turns" => 2}
  end

  test "workflow entry applies same-level libraries in declaration order" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(Path.join(library_root, "first.yml"), "agent:\n  max_turns: 20\n")
    File.write!(Path.join(library_root, "second.yml"), "agent:\n  max_turns: 40\n")

    File.write!(
      entry,
      "---\ninclude:\n  - ../workflow-libraries/first.yml\n  - ../workflow-libraries/second.yml\n---\n"
    )

    assert {:ok, %{config: %{"agent" => %{"max_turns" => 40}}}} = Workflow.load(entry)
  end

  test "workflow entry rejects an include outside the workflow library root" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    outside_library = Path.join(root, "outside.yml")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(outside_library, "tracker:\n  kind: memory\n")
    File.write!(entry, "---\ninclude:\n  - ../../outside.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../../outside.yml", :outside_workflow_library_root}} =
             Workflow.load(entry)
  end

  test "workflow entry rejects an absolute include inside the workflow library root" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    library_path = Path.join(library_root, "github-serial.yml")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(library_path, "tracker:\n  kind: memory\n")
    File.write!(entry, "---\ninclude:\n  - #{library_path}\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, ^library_path, :must_be_relative}} =
             Workflow.load(entry)
  end

  test "workflow entry rejects an absolute prompt file inside the workflow library root" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    prompt_path = Path.join(library_root, "github-serial.md")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(prompt_path, "Shared prompt\n")
    File.write!(entry, "---\nprompt_file: #{prompt_path}\n---\n")

    assert {:error, {:invalid_workflow_prompt_file, ^entry, ^prompt_path, :must_be_relative}} =
             Workflow.load(entry)
  end

  test "workflow entry rejects a prompt file combined with an inline prompt" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(Path.join(library_root, "github-serial.md"), "Shared prompt\n")

    File.write!(
      entry,
      "---\nprompt_file: ../workflow-libraries/github-serial.md\n---\nInline prompt\n"
    )

    assert {:error, {:invalid_workflow_prompt_file, ^entry}} = Workflow.load(entry)
  end

  test "workflow entry rejects a symbolic link used as a library source" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    outside_library = Path.join(root, "outside.yml")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(outside_library, "tracker:\n  kind: memory\n")
    File.ln_s!(outside_library, Path.join(library_root, "escaped.yml"))
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/escaped.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/escaped.yml", :workflow_library_source_must_not_be_symlink}} = Workflow.load(entry)
  end

  test "workflow entry rejects a workflow library root that is a symbolic link" do
    root = temporary_root()
    entry = Path.join(root, "my/stock_manage/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    outside_root = Path.join(root, "outside-workflow-libraries")

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(outside_root)
    File.write!(Path.join(outside_root, "github-serial.yml"), "tracker:\n  kind: memory\n")
    File.ln_s!(outside_root, library_root)
    File.write!(entry, "---\ninclude:\n  - ../workflow-libraries/github-serial.yml\n---\n")

    assert {:error, {:invalid_workflow_include, ^entry, "include", :workflow_library_root_must_not_be_symlink}} = Workflow.load(entry)
  end

  defp temporary_root do
    root = Path.join(System.tmp_dir!(), "symphony-workflow-composition-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end
end
