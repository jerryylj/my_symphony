defmodule SymphonyElixir.WorkflowStoreCompositionTest do
  use SymphonyElixir.TestSupport

  test "workflow store reloads when a referenced prompt changes" do
    root = Path.join(System.tmp_dir!(), "symphony-workflow-store-composition-#{System.unique_integer([:positive])}")
    entry = Path.join(root, "my/project/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    prompt_path = Path.join(library_root, "github-serial.md")

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(Path.join(library_root, "github-serial.yml"), "tracker:\n  kind: memory\n")
    File.write!(prompt_path, "First shared prompt\n")

    File.write!(
      entry,
      """
      ---
      include:
        - ../workflow-libraries/github-serial.yml
      prompt_file: ../workflow-libraries/github-serial.md
      codex:
        command: codex app-server
      ---
      """
    )

    Workflow.set_workflow_file_path(entry)
    assert {:ok, %{prompt: "First shared prompt"}} = Workflow.current()

    File.write!(prompt_path, "Second shared prompt\n")

    assert :ok = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second shared prompt"}} = Workflow.current()

    File.rm!(prompt_path)

    assert {:error, :enoent} = WorkflowStore.force_reload()
    assert {:ok, %{prompt: "Second shared prompt"}} = Workflow.current()
  end

  test "workflow store reloads and recovers from a referenced YAML library" do
    root = Path.join(System.tmp_dir!(), "symphony-workflow-store-library-#{System.unique_integer([:positive])}")
    entry = Path.join(root, "my/project/WORKFLOW.md")
    library_root = Path.join(root, "my/workflow-libraries")
    library_path = Path.join(library_root, "github-serial.yml")

    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.dirname(entry))
    File.mkdir_p!(library_root)
    File.write!(library_path, "tracker:\n  kind: memory\npolling:\n  interval_ms: 1000\n")

    File.write!(
      entry,
      """
      ---
      include:
        - ../workflow-libraries/github-serial.yml
      codex:
        command: codex app-server
      ---
      """
    )

    Workflow.set_workflow_file_path(entry)
    assert Config.settings!().polling.interval_ms == 1000

    File.write!(library_path, "tracker:\n  kind: memory\npolling:\n  interval_ms: 2000\n")

    assert :ok = WorkflowStore.force_reload()
    assert Config.settings!().polling.interval_ms == 2000

    File.write!(library_path, "tracker: [\n")

    assert {:error, {:invalid_workflow_include, ^entry, "../workflow-libraries/github-serial.yml", _}} =
             WorkflowStore.force_reload()

    assert Config.settings!().polling.interval_ms == 2000
  end
end
