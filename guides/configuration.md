# Packet Manifest Reference

Prompt Runner 0.12.0 uses two primary authoring files:

- `prompt_runner_packet.md`
- `*.prompt.md`

Both are markdown documents with YAML front matter.

Optional supporting authoring files include:

- `templates/*.prompt.md`
- packet-local docs such as `docs/*.md`

## Packet Manifest

Recommended filename:

- `prompt_runner_packet.md`

Example:

```markdown
---
name: "demo"
profile: "codex-default"
prompt_template: "from-adr"
provider: "codex"
model: "gpt-5.6-luna"
reasoning_effort: "xhigh"
permission_mode: "bypass"
allowed_tools:
  - "Read"
  - "Edit"
  - "Write"
  - "Bash"
cli_confirmation: "require"
recovery:
  resume_attempts: 2
  retry:
    max_attempts: 3
    base_delay_ms: 1000
    max_delay_ms: 30000
    jitter: true
  repair:
    enabled: true
    max_attempts: 2
    trigger_on_nominal_success_with_failed_verifier: true
    trigger_on_provider_failure_with_workspace_changes: true
    trigger_on_retry_exhaustion_with_workspace_changes: true
agent_control:
  enabled: true
  default_action: "repeat"
  max_iterations: 20
  completion_verify:
    commands:
      - exec: "@repo:app/scripts/verify_complete"
        args: []
        timeout_ms: 600000
repos:
  app:
    path: "./workspace"
    default: true
phases:
  "1": "Bootstrap"
  "2": "Wrap Up"
---
# Demo Packet
```

### Packet Keys

Core keys:

- `name`
- `profile`
- `prompt_template`
- `repos`
- `phases`
- `recovery`
- `agent_control`

Shared execution keys:

- `provider`
- `model`
- `permission_mode`
- `allowed_tools`
- `timeout`
- `log_mode`
- `log_meta`
- `events_mode`
- `tool_output`

Provider-specific keys:

- `adapter_opts`
- `sdk_opts`
- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `amp_opts`
- `cursor_opts`
- `antigravity_opts`
- `system_prompt`
- `append_system_prompt`
- `max_turns`
- `cli_confirmation`

Every provider option map also accepts the normalized common options
(`allow_unknown_model`, `completion_only`, `output_schema`,
`transport_headless_timeout_ms`). See the
[Provider Guide](providers.md) for which providers support each one at
runtime.

### `agent_control`

`agent_control` lets a provider control an ordinary linear prompt sequence
after each verified iteration:

- `continue` completes the current prompt and advances;
- `repeat` runs the current prompt again in a fresh provider session;
- `finish` closes the sequence only after `completion_verify` passes;
- `blocked` stops incomplete and records the stated reason.

`default_action` is `continue` or `repeat`, `max_iterations` is a positive
per-prompt cap, and `completion_verify` is a non-empty ordinary verifier
contract. See [Agent-Controlled Linear Runs](agent-control.md).

### `timeout` And The Run Deadline

`timeout` (milliseconds, packet-level or prompt-level) is the single lever for
how long a session may take. `PromptRunner.Session` derives four bounds from
it:

| Bound | Derived as |
|-------|-----------|
| stream timeout | the configured timeout |
| transport timeout | the configured timeout |
| stream idle timeout | `max(120_000, timeout + 30_000)` |
| ASM `run_deadline_ms` | the configured timeout |

The run deadline is a total wall-clock budget for the whole run, armed
independently of the stream and transport bounds. `ASM.Run.State` defaults it
to 600_000 — ten minutes — and Prompt Runner did not set it before 0.9.0. A
packet that deliberately left `timeout` unset therefore got seven days on the
stream and transport bounds and **ten minutes on the run**, and every prompt
doing more than a few minutes of work was killed with a
`provider_runtime_claim` naming a deadline nothing had configured, after the
model had already done the work.

Since 0.9.0 all four derive from the same value:

- **`timeout` unset** — the seven-day emergency bound, not ASM's 600s default.
  This is the right posture for prompts sized in tens of minutes.
- **`timeout` set** — that value bounds the run as well. A small `timeout` also
  shrinks the idle bound, and a high-reasoning session can go minutes between
  stream events, so set it deliberately or not at all.
- `unbounded`, `infinity`, and `infinite` all resolve to the seven-day bound.

`stream_idle_timeout` is not a packet or prompt key. It exists only inside
`PromptRunner.Session` and is derived, never configured directly.

## Prompt Front Matter

Recommended filename pattern:

- `01_create_hello.prompt.md`

Example:

```markdown
---
id: "01"
phase: 1
name: "Create hello file"
template: "from-adr"
targets:
  - "app"
commit: "docs: add hello file"
provider: "codex"
model: "gpt-5.6-luna"
verify:
  files_exist:
    - "hello.txt"
  contains:
    - path: "hello.txt"
      text: "Hello from Prompt Runner"
  commands:
    - exec: "test"
      args: ["-s", "hello.txt"]
      timeout_ms: 60000
  changed_paths_only:
    - "hello.txt"
---
# Create hello file

## Required Reading

- `docs/adr-001-runtime-boundaries.md`

## Mission

Create `hello.txt` with exactly one line: `Hello from Prompt Runner`.
```

The filename must carry the same numeric prefix as `id:`. Prompts are ordered
by the filename prefix, not by `id:`, so a mismatch silently reorders the run.
`mix prompt_runner packet lint` reports it as an error.

### Prompt Keys

Scheduling and identity:

- `id`
- `phase`
- `name`
- `template`
- `targets`
- `commit`

### Parsed But Never Sent to the Provider

- `references`
- `required_reading`
- `context_files`

These three are accepted, normalized, and stored on `PromptRunner.Prompt`, and
then never read at runtime. They are **not** sent to the provider — only the
markdown body after the front matter is.

`depends_on` is different: the scheduler validates it, orders selected prompts
topologically, and blocks descendants of a failed dependency. It still is not
provider context, so describe the dependency's substance in the prompt body.

Write required reading into the prompt body, where the model will see it.
`mix prompt_runner packet lint` warns when a prompt carries any of the inert keys, and
since 0.9.0 the scaffolding templates no longer emit them.

Prompt-local execution overrides:

- `provider`
- `model`
- `reasoning_effort`
- `permission_mode`
- `recovery`
- `allowed_tools`
- `sdk_opts`
- `adapter_opts`
- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `amp_opts`
- `cursor_opts`
- `antigravity_opts`
- `cli_confirmation`
- `timeout`
- `system_prompt`
- `append_system_prompt`
- `max_turns`

Completion contract:

- `verify`
- `simulate`

Prompt-local `recovery` is deep-merged onto the packet default. Use it when a
single prompt needs a tighter or more generous retry/repair budget than the
rest of the packet.

Example:

```yaml
recovery:
  retry:
    class_attempts:
      provider_runtime_claim: 1
```

## Completion Contract Keys

Prompt Runner 0.12.0 supports:

- `files_exist`
- `files_absent`
- `contains`
- `matches`
- `doc`
- `yaml`
- `json`
- `glob`
- `source_absent`
- `commands`
- `changed_paths_only`
- `repos_clean`

Entries can be repo-scoped:

```yaml
verify:
  files_exist:
    - repo: "alpha"
      path: "NOTES.md"
```

`doc:` is an artifact-quality gate for written deliverables, and `repos_clean:`
asserts that sessions committed (and optionally pushed) their own work:

```yaml
verify:
  doc:
    - path: "docs/report.md"
      min_lines: 100
      requires_sections: ["## Method", "## Verdict"]
      forbids_markers: ["TODO", "TBD", "FIXME"]
  repos_clean:
    - repo: "app"
      pushed: true
```

Use structured `commands:` entries with `exec`, `args`, and a positive
`timeout_ms`. Prompt Runner executes that argv directly, without a login shell
or shell interpolation. Optional `cwd`, `env`, `fault_exit_codes`,
`stdout_contains`, and `stdout_matches` fields make the execution environment
and verdict explicit. String and `run:` entries exist only for legacy packet
compatibility and fail strict lint.

Anything else under `verify:` is rejected by packet lint as an unknown clause.

Structured command entries may declare `regenerates: [relative/path]`. Prompt
Runner moves any prior output to a recoverable adjacent backup, runs the argv
without a shell, requires every declared output to be a newly created non-empty
regular file, and restores the prior outputs if the command fails. A successful
check removes the backups. This prevents a stale generated artifact from making
a no-op generator look successful.
`mix prompt_runner packet lint` reports an unrecognized clause as an error.
See [Verification And Repair](verification-and-repair.md) for the full clause
reference.

## Generated Checklist Files

`mix prompt_runner checklist sync` converts the deterministic contract into a
human-readable checklist file next to each prompt.

The checklist is derived output, not the source of truth.

If a prompt still has no verifier items, `checklist sync` prints a warning and
the generated checklist explicitly says that verification items are still
missing.

`mix prompt_runner packet preflight` reports runtime readiness as JSON and
exits non-zero when packet-local repos or git state are not ready. `run` calls
this gate before invoking a provider unless `--skip-preflight` is explicit.

`mix prompt_runner packet doctor` also reports common authoring gaps:

- packet has no prompts
- packet has no default repo
- prompt has no targets
- prompt has no verification items
- prompt still contains scaffold placeholder markers

`mix prompt_runner packet lint` reports authoring *hazards* rather than gaps:
constructs that load and run and quietly mean something else. See
[Packet Linting](linting.md).

## Simulated Provider Scripts

When `provider: "simulated"` is active, prompts can define deterministic
recovery scripts:

```yaml
simulate:
  attempts:
    - error:
        kind: "provider_capacity"
        message: "Selected model is at capacity. Please try again."
    - writes:
        - path: "retry.txt"
          text: "retry ok"
  resume:
    writes:
      - path: "resumed.txt"
        text: "resumed ok"
```

Supported simulation keys:

- `attempts`
- `resume`

Each step can include:

- `messages`
- `writes`
- `error`
- `error.recovery`
