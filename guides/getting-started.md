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
mix prompt_runner template list
```

This creates:

```text
~/.config/prompt_runner/
  config.md
  profiles/
    codex-default.md
    simulated-default.md
  templates/
    default.prompt.md
    from-adr.prompt.md
```

## Create A Packet

Start with the simulated path first so you can prove the packet shape and
verification contracts without any external CLI setup:

```bash
mix prompt_runner packet new demo \
  --profile simulated-default \
  --provider simulated \
  --model simulated-demo \
  --repo app=/path/to/repo \
  --default-repo app \
  --prompt-template from-adr

mix prompt_runner prompt new 01 \
  --packet demo \
  --phase 1 \
  --name "Capture runtime boundaries" \
  --targets app \
  --commit "docs: add runtime boundaries summary"
```

The new prompt is created from the selected template. You should then edit it to
add source material and a deterministic verifier contract.

For a finished example of this authoring flow, see
[`examples/authoring_packet/`](../examples/authoring_packet/README.md).

## Optional: Create A Ready-To-Demo Recovery Packet

If you want the recovery walkthrough specifically:

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
  templates/
  prompts/
    01_capture_runtime_boundaries.prompt.md
```

## Add Source Material And A Deterministic Contract

Edit `demo/prompts/01_capture_runtime_boundaries.prompt.md`:

```markdown
---
id: "01"
phase: 1
name: "Capture runtime boundaries"
template: "from-adr"
targets:
  - "app"
commit: "docs: add runtime boundaries summary"
references:
  - "docs/adr-001-runtime-boundaries.md"
required_reading:
  - "docs/adr-001-runtime-boundaries.md"
context_files:
  - "workspace/README.md"
depends_on: []
verify:
  files_exist:
    - "RUNTIME_BOUNDARIES.md"
  contains:
    - path: "RUNTIME_BOUNDARIES.md"
      text: "Prompt Runner owns packet orchestration."
  changed_paths_only:
    - "RUNTIME_BOUNDARIES.md"
---
# Capture runtime boundaries

## Required Reading

- `docs/adr-001-runtime-boundaries.md`

## Mission

Read ADR 001 and create `RUNTIME_BOUNDARIES.md` in the target repo.

## Deliverables

- `RUNTIME_BOUNDARIES.md` summarizing the runtime boundary split

## Non-Goals

Do not modify any other files. Respond with exactly `ok`.
```

Generate the checklist view:

```bash
mix prompt_runner checklist sync demo
mix prompt_runner packet doctor demo
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

- [From ADRs To Packets](from-adrs-to-packets.md)
- [CLI Guide](cli.md)
- [API Guide](api.md)
- [Packet Manifest Reference](configuration.md)
- [Templates](templates.md)
- [Profiles](profiles.md)
- [Simulated Provider](simulated-provider.md)
- [Verification And Repair](verification-and-repair.md)
- [Examples](../examples/README.md)
