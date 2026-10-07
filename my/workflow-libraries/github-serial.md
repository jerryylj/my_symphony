You are executing GitHub Issue `{{ issue.identifier }}` in the repository checked out in this
workspace. Before using `github_api`, derive its canonical `owner/repo` value from the `origin`
remote and verify that it agrees with `{{ issue.url }}`. If you cannot derive or verify it, record
the exact blocker on the current issue and stop. In every GitHub API path below, replace
`<repository>` with that verified value.

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
   `GET /repos/<repository>/issues/{current_number}/timeline` and collect cross-references whose
   source is a pull request. If the workspace is on a non-default branch, also look up
   `GET /repos/<repository>/pulls?head=<owner>:<branch>&state=all`.
3. For each candidate, fetch its real pull request with
   `GET /repos/<repository>/pulls/{candidate_pr_number}`.
4. If exactly one candidate is already merged into the repository's default branch, skip implementation,
   publishing, and merging, then go directly to recovery handoff below. Do not repeat development.
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
4. Publish directly: push the current branch with `git push -u origin <branch>`, then create or update
   its pull request with `gh pr create`. Include `Refs #<current_number>` in the PR body so the issue has
   a durable association with its PR. Do not use auto-close keywords such as `Closes`; GitHub must not
   close the current issue before handoff is complete.
5. Fetch the actual pull request, require its required checks to pass and that it is mergeable into the
   default branch, then merge it directly with `gh pr merge <actual_pr_number> --squash --delete-branch`.
   Do not use `--admin`, auto-merge, or a substitute issue number. If the merge command fails, inspect
   the real failure; retry only transient failures, otherwise record the exact blocker on the current
   issue and stop without releasing a successor.
6. Keep a concise status comment on the current issue at meaningful handoff points and whenever a
   blocker or human confirmation is required. Do not add duplicate status comments.

## Completion gate

Creating or publishing a pull request is not ticket completion. In the same turn, inspect the current
issue's associated pull request and, once its required checks pass and it is mergeable, directly squash
merge it with `gh pr merge`. An open pull request is never an acceptable final status; a merged pull
request requires the handoff below. Never spend a continuation turn on unrelated implementation once a
pull request exists.

## Handoff

A handoff is valid only after the direct merge command is confirmed by GitHub: the current ticket's
actual pull request must be merged into the repository's default branch. Use the PR number or URL
returned by `gh pr create`; if it is unavailable, resolve it from the current branch with
`GET /repos/<repository>/pulls?head=<owner>:<branch>&state=all`. Never substitute the current issue
number for the PR number.

Verify that real PR through `github_api`:

1. `GET /repos/<repository>` and record `default_branch`.
2. `GET /repos/<repository>/pulls/{actual_pr_number}` and require:
   - `state` is `closed`,
   - `merged` is true,
   - `base.ref` equals `default_branch`.
3. If any check fails, the ticket remains incomplete. Leave the current issue open, record the exact
   failed handoff check on it, and do not label any other issue.

After a valid merge, advance by exactly one GitHub number:

`ready-for-agent` is Matt's triage label: the issue is specified and suitable for agent work.
`agent-ready` is Symphony's dispatch label: an issue must have it to be picked up by this
workflow. The labels may coexist, but `ready-for-agent` never substitutes for `agent-ready`.
Compare their complete names, not their similar meanings.

1. Compute `successor_number = current_number + 1`.
2. `GET /repos/<repository>/issues/{successor_number}`.
3. If the successor is absent, closed, or contains a `pull_request` object, close the current issue
   and end the sequence successfully. Do not skip it or select another issue.
4. If the successor is an open issue, report its actual label names and whether the exact
   `agent-ready` label is present. Having only `ready-for-agent` means `agent-ready` is missing.
   If missing, add `agent-ready` with `POST /repos/<repository>/issues/{successor_number}/labels`,
   then `GET /repos/<repository>/issues/{successor_number}` again and confirm the exact label is
   present. Retry transient GitHub failures. If adding or confirming fails, record the blocker on
   the current issue, leave it open, and stop.
5. Report the confirmed successor label result. Only after confirming that the immediate successor
   has `agent-ready`, close the current issue. If a process was interrupted after successor
   enablement, recovery must add the missing label first, then close the current issue once.
6. If there is no valid successor, close the current issue after the merge verification and stop
   successfully.

When entering recovery handoff because the recovery gate found an already merged PR, perform only
the post-merge steps: verify the real PR, idempotently ensure the immediate successor has
`agent-ready`, then close the current issue. Do not repeat implementation, publishing, or merging.

Never label a successor while the current issue is unmerged, blocked, awaiting confirmation, or
otherwise incomplete. Never label more than the immediate successor. Symphony retains its normal
retry behavior for the current issue; retries may continue that ticket but must not release the next
one.
