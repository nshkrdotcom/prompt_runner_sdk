# Agent-Controlled Linear Runs

Prompt Runner 0.12.0 lets an agent control movement through an ordinary ordered
prompt sequence without introducing a workflow graph.

The runner still owns scheduling and completion. The agent can request one of
four actions after a prompt iteration:

| Directive | Result |
|---|---|
| `continue` | Complete the current prompt and move to the next selected prompt. |
| `repeat` | Run the current prompt again in a fresh provider session. |
| `finish` | End the selected sequence successfully, but only after packet-level completion verification passes. |
| `blocked` | Stop with an incomplete result and record the exact reason. |

This supports both repeated continuation prompts and more complex linear
packets. A prompt can repeat several times, continue to the next prompt, or
finish the whole sequence when its objective is proven complete.

## Packet Configuration

Add `agent_control` to `prompt_runner_packet.md`:

```yaml
agent_control:
  enabled: true
  default_action: "repeat"
  max_iterations: 20
  completion_verify:
    commands:
      - exec: "@repo:app/scripts/verify_complete"
        args: []
        timeout_ms: 600000
    repos_clean:
      - repo: "app"
        pushed: true
      - repo: "docs"
        pushed: true
```

`completion_verify` uses the same clauses as a prompt's `verify` contract. It
must contain at least one real verifier item. A provider statement such as
"everything is done" is never completion evidence.

Configuration keys:

- `enabled` — defaults to `true` when the block exists.
- `default_action` — `continue` or `repeat`; used when the agent issues no
  directive.
- `max_iterations` — positive per-prompt invocation cap; defaults to 20.
- `completion_verify` — deterministic packet-level contract required by
  `finish` and evaluated before a non-explicit run begins.

The `agent_control` block participates in the packet fingerprint. Changing it
during a failed or interrupted run requires the ordinary reviewed `--new-run`
supersession.

## Agent Commands

During an enabled provider session, Prompt Runner adds the exact commands to
the prompt and scopes them to that run, prompt, and iteration:

```bash
prompt_runner agent-control continue
prompt_runner agent-control repeat --reason "work remains"
prompt_runner agent-control finish --reason "the full packet objective is complete"
prompt_runner agent-control blocked --reason "missing deployment credentials"
```

`finish` and `blocked` require `--reason`. The first accepted directive wins;
a second directive from the same iteration is rejected.

The command is unavailable outside a live controlled invocation. Prompt Runner
passes a private request path, opaque token, run id, prompt id, and iteration in
the provider subprocess environment. The runner authenticates all five fields
before acting on the request.

## Exact Execution Semantics

1. For a normal packet run, Prompt Runner evaluates `completion_verify` before
   opening a provider. If it already passes, the run exits successfully with no
   session. Explicit prompt ids still run because naming one is an explicit
   request.
2. Prompt Runner starts the selected prompt iteration and exposes its scoped
   control command.
3. The provider finishes. The prompt's ordinary `verify` contract must pass,
   and any runner-owned commit must succeed, before a directive is consumed.
   A failed provider launch or turn is never accepted as a controlled iteration,
   even if the ordinary contract independently passes.
4. `continue` records the prompt complete and advances.
5. `repeat` records the verified iteration but does not mark the prompt
   complete. A fresh provider session receives the original prompt plus the
   next iteration number.
6. `finish` runs `completion_verify`. A pass records the current prompt
   complete and closes the selected sequence. A failed contract is supplied to
   a fresh iteration so the agent can finish the missing work; a verifier fault
   stops immediately as infrastructure failure.
7. `blocked` records the prompt as incomplete and returns a non-zero result.
8. Reaching `max_iterations` returns
   `{:agent_control_iteration_limit, prompt_id, max_iterations}` and leaves the
   prompt resumable.

Provider retry and repair stay inside one iteration. If a provider wrote a
directive before the ordinary verifier failed, Prompt Runner discards that
request before the repair session so the repaired iteration must choose again.

## Repeat-Until-Complete

A single continuation prompt is the smallest use case:

```yaml
agent_control:
  enabled: true
  default_action: "repeat"
  max_iterations: 20
  completion_verify:
    commands:
      - exec: "@repo:docs/scripts/verify_project_complete"
        args: []
        timeout_ms: 600000
```

The prompt should begin by checking whether any work remains. If work remains,
it performs a coherent unit, refreshes the handoff, commits and pushes, and
requests `repeat`. If no work remains, it refreshes the final completion record,
commits and pushes, and requests `finish`.

The safety properties do not depend on the agent choosing correctly:

- premature `finish` is rejected by `completion_verify`;
- provider failure cannot fall through to the declared default action;
- forgotten directives use the declared default;
- repeated work stops at the iteration cap;
- an emergency operator stop remains `prompt_runner stop --workspace ...` and
  is never used to report success.

## Workspace Runs

Require the feature in the workspace manifest:

```yaml
requires:
  prompt_runner: ">= 0.12.0 and < 0.13.0"
  capabilities:
    - agent_control.linear
    - verifier.argv
    - containment.systemd_user
    - workspace.independent_clone
```

Then use the normal workspace lifecycle:

```bash
prompt_runner workspace prepare workspace.yml
prompt_runner workspace doctor workspace.yml
prompt_runner packet lint packet --strict
prompt_runner start --workspace workspace.yml --packet packet --remaining --no-commit
```

The installed escript that starts the workspace must be 0.12.0 or newer. The
provider invokes that same installed command through its inherited `PATH`.
