# Packet Manifest Reference

Prompt Runner 0.7.0 uses two authoring files:

- `prompt_runner_packet.md`
- `*.prompt.md`

Both are markdown documents with YAML front matter.

## Packet Manifest

Recommended filename:

- `prompt_runner_packet.md`

Example:

```markdown
---
name: "demo"
profile: "codex-default"
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
retry_attempts: 2
auto_repair: true
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
- `repos`
- `phases`
- `retry_attempts`
- `auto_repair`

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
targets:
  - "app"
commit: "docs: add hello file"
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
- `targets`
- `commit`

Prompt-local execution overrides:

- `provider`
- `model`
- `reasoning_effort`
- `permission_mode`
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
