# Getting Started

This guide targets `prompt_runner_sdk ~> 0.7.0`.

## Install

```elixir
def deps do
  [
    {:prompt_runner_sdk, "~> 0.7.0"}
  ]
end
```

```bash
mix deps.get
```

## Provider Credentials

Set the CLI credentials your chosen provider expects:

| Provider | Env Var |
|----------|---------|
| Claude | `ANTHROPIC_API_KEY` |
| Codex | `OPENAI_API_KEY` |
| Gemini | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Amp | `AMP_API_KEY` |

For local recovery demos, you can skip provider credentials entirely and use
the built-in `simulated` provider.

## Initialize Prompt Runner

Initialize the home-scoped profile store once:

```bash
mix prompt_runner init
```

This creates:

```text
~/.config/prompt_runner/
  config.md
  profiles/
    codex-default.md
    simulated-default.md
```

## Create A Packet

```bash
mix prompt_runner packet new demo
mix prompt_runner repo add app /path/to/repo --packet demo --default
mix prompt_runner prompt new 01 \
  --packet demo \
  --phase 1 \
  --name "Create hello file" \
  --targets app \
  --commit "docs: add hello file"
```

Or create a ready-to-demo simulated packet:

```bash
mix prompt_runner packet new recovery-demo \
  --profile simulated-default \
  --provider simulated \
  --model simulated-demo \
  --permission bypass
```

That creates:

```text
demo/
  prompt_runner_packet.md
  prompts/
    01_create_hello_file.prompt.md
```

If you want the recovery posture to be explicit in the packet itself, add a
`recovery:` block to `recovery-demo/prompt_runner_packet.md`:

```yaml
recovery:
  resume_attempts: 2
  retry:
    max_attempts: 3
    base_delay_ms: 0
    max_delay_ms: 0
    jitter: false
  repair:
    enabled: true
    max_attempts: 2
    trigger_on_nominal_success_with_failed_verifier: true
    trigger_on_provider_failure_with_workspace_changes: true
    trigger_on_retry_exhaustion_with_workspace_changes: true
```

## Add A Deterministic Contract

Edit `demo/prompts/01_create_hello_file.prompt.md`:

```markdown
---
id: "01"
phase: 1
name: "Create hello file"
targets:
  - "app"
commit: "docs: add hello file"
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
Do not modify any other files. Respond with exactly `ok`.
```

Generate the checklist view:

```bash
mix prompt_runner checklist sync demo
```

## Inspect And Run

```bash
mix prompt_runner list demo
mix prompt_runner plan demo
mix prompt_runner run demo
mix prompt_runner status demo
```

`status` prints `.prompt_runner/state.json` as formatted JSON.

## What Gets Created At Runtime

CLI packet runs create:

```text
demo/
  .prompt_runner/
    state.json
    progress.log
    logs/
```

API runs default to in-memory state plus a no-op committer unless you opt into
file-backed state or git commits.

## Next Steps

- [CLI Guide](cli.md)
- [API Guide](api.md)
- [Packet Manifest Reference](configuration.md)
- [Profiles](profiles.md)
- [Simulated Provider](simulated-provider.md)
- [Verification And Repair](verification-and-repair.md)
- [Examples](../examples/README.md)
