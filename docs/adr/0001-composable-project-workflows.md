# Compose project workflows from controlled shared libraries

<!-- status: accepted -->

`stock_manage` and `vedio_monitor_model` repeat the same GitHub serial-agent flow while needing
different repository, workspace, credential-path, and turn-limit settings. Symphony will resolve a
project-owned workflow entry from ordered, repository-owned YAML libraries plus one shared Markdown
prompt. The entry overrides libraries through documented deep-merge rules; its existing behavioural
differences remain explicit rather than being normalised away.

## Interface

The front matter of a workflow entry gains two composition-only keys, removed before the resulting
configuration reaches `Config.Schema`:

```yaml
include:
  - ../workflow-libraries/github-serial.yml
prompt_file: ../workflow-libraries/github-serial.md
```

`include` is an ordered list of YAML fragments. Libraries may themselves include earlier libraries.
Mappings merge recursively, while lists and scalar values in the later source replace earlier
values. The entry is always last, so its settings win. `prompt_file` is one Markdown file, resolved
relative to the entry; it replaces the entry Markdown body and is the prompt passed to the existing
prompt renderer.

The resolver must accept only relative paths whose canonical locations remain under
`my/workflow-libraries/`; it must reject absolute paths, escapes, missing files, non-YAML includes,
cycles, symbolic-link roots or sources, and more than one prompt source. Its error must identify the
referring source and invalid path. All resolved source paths and content fingerprints form the workflow-store reload stamp, so
changing a library reloads every entry that refers to it while a failed reload retains the last known
good effective workflow.

The shared GitHub prompt must infer its repository from the checked-out `origin` remote and verify
that it agrees with the current issue URL. It must not hard-code a repository name or receive tracker
credentials through template context.

## Target layout

```text
my/
├── workflow-libraries/
│   ├── github-serial.yml          # GitHub states/labels, polling, common hook timeout and defaults
│   └── github-serial.md           # repository-agnostic serial issue/PR/recovery instructions
├── stock_manage/
│   ├── WORKFLOW.md                # includes library; repo, workspace, clone hook, 2-turn policy
│   └── start-service.sh           # remains the project launcher and secret-file owner
└── vedio_monitor_model/
    ├── WORKFLOW.md                # includes library; repo, workspace, clone hook, 40-turn policy
    └── start-service.sh           # remains the project launcher and secret-file owner
```

The runtime implementation belongs behind one workflow-resolution seam:

```text
elixir/lib/symphony_elixir/workflow/source_resolver.ex
    resolve(entry_path) -> effective config, prompt, source paths/fingerprints
elixir/lib/symphony_elixir/workflow.ex
    delegates loading to SourceResolver; preserves the existing public load interface
elixir/lib/symphony_elixir/workflow_store.ex
    stamps every resolved source, not only the entry file
elixir/test/symphony_elixir/workflow_composition_test.exs
    merge, precedence, path containment, cycle, prompt, and reload-dependency coverage
```

`Workflow` remains the caller-facing module. `SourceResolver` contains filesystem traversal,
composition rules, and diagnostic complexity, so the rest of Symphony still consumes a single
effective workflow.

## Considered options

- **Copy full files:** easy initially but loses locality; every flow correction must be duplicated.
- **Symbolic links:** cannot express project-specific configuration or deliberate agent-limit
  differences.
- **General YAML templating:** unnecessarily broad and risks making configuration/secret expansion
  implicit. Composition is restricted to explicit YAML and prompt sources instead.
