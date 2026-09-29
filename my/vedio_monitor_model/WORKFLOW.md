---
tracker:
  kind: github
  provider:
    repo: jerryylj/vedio_monitor_model
  required_labels:
    - agent-ready
  active_states:
    - open
  terminal_states:
    - closed
polling:
  interval_ms: 5000
workspace:
  root: ~/code/vedio-monitor-model-symphony-workspaces
hooks:
  after_create: |
    gh repo clone jerryylj/vedio_monitor_model . -- --depth 1
agent:
  max_concurrent_agents: 1
  max_turns: 40
codex:
  command: env -u http_proxy -u https_proxy -u all_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY -u no_proxy -u NO_PROXY codex --profile volcengine --config shell_environment_policy.inherit=all --config model_reasoning_effort=xhigh app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_sandbox_policy:
    type: workspaceWrite
    networkAccess: true
---

You are executing GitHub Issue `{{ issue.identifier }}` in `jerryylj/vedio_monitor_model`.

Issue context:

- Title: `{{ issue.title }}`
- State: `{{ issue.state }}`
- Labels: `{{ issue.labels }}`
- URL: `{{ issue.url }}`

Description:

{% if issue.description %}
{{ issue.description }}
{% else %}
No description was provided.
{% endif %}

{% if attempt %}
This is attempt `{{ attempt }}`. Resume from the existing workspace. Reconcile what was already
done before doing it again. Never release a successor merely because a previous attempt ended.
{% endif %}

This is an unattended serial ticket sequence. There may be no human available to answer questions.
Do not invent missing product behavior. If a required external tool, permission, secret, or ticket
decision is missing, use `github_api` to record the blocker on the current issue, leave it open, and
stop without touching any other issue.

## Scope

Implement only the current issue. Do not modify Symphony source, bundled workflow examples,
project documentation, tests, or checked-in skills unless the issue explicitly requires it. Do not
modify or replace Matt's skills.

Use Symphony's configured `github_api` tool for all GitHub issue reads, comments, labels, and state
changes. Do not read, copy, or forward tracker credentials. Do not use the GitHub API tool for
unrelated issues.

## Recovery gate

Before starting or retrying development, check whether the current issue already has an associated
merged pull request:

1. Determine the current GitHub issue number from `GH-<number>`. Never treat this number as a pull
   request number.
2. Inspect the issue timeline with
   `GET /repos/jerryylj/vedio_monitor_model/issues/{current_number}/timeline` and collect
   cross-references whose source is a pull request. If the workspace is on a non-default branch,
   also look up
   `GET /repos/jerryylj/vedio_monitor_model/pulls?head=jerryylj:<branch>&state=all`.
3. For each candidate, fetch its real pull request with
   `GET /repos/jerryylj/vedio_monitor_model/pulls/{candidate_pr_number}`.
4. If exactly one candidate is already merged into the repository's default branch, skip `$implement`,
   `$push`, and `$land`, then go directly to recovery handoff below. Do not repeat development.
5. If more than one merged PR is associated with the issue, record the ambiguity on the issue, leave
   it open, and do not label any successor.
6. If no associated PR is merged, continue with the normal execution flow.

## Execution

1. Parse the numeric ticket number from `GH-<number>`. Treat that issue as current.
2. Sync the workspace with `origin`'s default branch before implementation. If a prior attempt left
   a valid branch, review it before deciding whether to continue it or restart from the default
   branch. Never base work on a predecessor ticket's changes.
3. Invoke Matt's `$implement` skill for the current ticket. That skill owns the implementation loop:
   use `$tdd` where a pre-agreed seam exists, run typechecking and targeted tests regularly, run the
   complete relevant test suite once at the end, run its own review step, and commit the work to the
   current branch. Do not invoke `$code-review` separately after `$implement`.
4. Publish with Matt's `$push` skill and merge with Matt's `$land` skill only through their existing
   flows. Do not merge directly and do not weaken a landing gate.
5. Require `$push` to include `Closes #<current_number>` in the PR body so the issue has a durable
   association with its PR.
6. Keep a concise status comment on the current issue at meaningful handoff points and whenever a
   blocker or human confirmation is required. Do not add duplicate status comments.

## Handoff

A handoff is valid only after `$land` confirms that the current ticket's actual pull request is
merged into the repository's default branch. Use the PR number or URL returned by `$push` or
`$land`; if it is unavailable, resolve it from the current branch with
`GET /repos/jerryylj/vedio_monitor_model/pulls?head=jerryylj:<branch>&state=all`. Never substitute
the current issue number for the PR number.

Verify that real PR through `github_api`:

1. `GET /repos/jerryylj/vedio_monitor_model` and record `default_branch`.
2. `GET /repos/jerryylj/vedio_monitor_model/pulls/{actual_pr_number}` and require:
   - `state` is `closed`,
   - `merged` is true,
   - `base.ref` equals `default_branch`.
3. If any check fails, the ticket remains incomplete. Leave the current issue open, record the exact
   failed handoff check on it, and do not label any other issue.

After a valid merge, advance by exactly one GitHub number:

1. Compute `successor_number = current_number + 1`.
2. `GET /repos/jerryylj/vedio_monitor_model/issues/{successor_number}`.
3. If the successor is absent, closed, or contains a `pull_request` object, close the current issue
   and end the sequence successfully. Do not skip it or select another issue.
4. If the successor is an open issue, inspect its labels. Add `agent-ready` only if that label is
   missing. Retry transient GitHub failures, but do not mark the current issue complete until the
   label has been confirmed.
5. If the current issue is still open, close it. If a process was interrupted after successor
   enablement, recovery must add the missing label first, then close the current issue once.
6. If there is no valid successor, close the current issue after the merge verification and stop
   successfully.

When entering recovery handoff because the recovery gate found an already merged PR, perform only
the post-merge steps: verify the real PR, idempotently ensure the immediate successor has
`agent-ready`, then close the current issue. Do not run `$implement`, `$push`, or `$land` again.

Never label a successor while the current issue is unmerged, blocked, awaiting confirmation, or
otherwise incomplete. Never label more than the immediate successor. Symphony retains its normal
retry behavior for the current issue; retries may continue that ticket but must not release the next
one.
