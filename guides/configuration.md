# Packet Manifest Reference

Prompt Runner 0.7.0 uses two primary authoring files:

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
model: "gpt-5.4"
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
- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `gemini_opts`
- `amp_opts`
- `system_prompt`
- `append_system_prompt`
- `max_turns`
- `cli_confirmation`

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
references:
  - "docs/adr-001-runtime-boundaries.md"
required_reading:
  - "docs/adr-001-runtime-boundaries.md"
context_files:
  - "workspace/README.md"
depends_on: []
provider: "codex"
model: "gpt-5.4"
verify:
  files_exist:
    - "hello.txt"
  contains:
    - path: "hello.txt"
      text: "Hello from Prompt Runner"
  changed_paths_only:
    - "hello.txt"
---
# Create hello file

## Mission

Create `hello.txt` with exactly one line: `Hello from Prompt Runner`.
```

### Prompt Keys

Scheduling and identity:

- `id`
- `phase`
- `name`
- `template`
- `targets`
- `commit`
- `references`
- `required_reading`
- `context_files`
- `depends_on`

Prompt-local execution overrides:

- `provider`
- `model`
- `reasoning_effort`
- `permission_mode`
- `recovery`
- `allowed_tools`
- `adapter_opts`
- `claude_opts`
- `codex_opts`
- `codex_thread_opts`
- `gemini_opts`
- `amp_opts`
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

Prompt Runner 0.7.0 supports:

- `files_exist`
- `files_absent`
- `contains`
- `matches`
- `commands`
- `changed_paths_only`

Entries can be repo-scoped:

```yaml
verify:
  files_exist:
    - repo: "alpha"
      path: "NOTES.md"
```

## Generated Checklist Files

`mix prompt_runner checklist sync` converts the deterministic contract into a
human-readable checklist file next to each prompt.

The checklist is derived output, not the source of truth.

If a prompt still has no verifier items, `checklist sync` prints a warning and
the generated checklist explicitly says that verification items are still
missing.

`mix prompt_runner packet doctor` also reports common authoring gaps:

- packet has no prompts
- packet has no default repo
- prompt has no targets
- prompt has no verification items
- prompt still contains scaffold placeholder markers

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
