# From ADRs To Packets

This guide covers the actual authoring journey:

- you have source docs and ADRs
- you have one or more target repos
- you do not yet have finished prompts

## 1. Start With A Packet

Initialize Prompt Runner once:

```bash
mix prompt_runner init
```

Create a packet and register repos up front:

```bash
mix prompt_runner packet new runtime-review \
  --profile simulated-default \
  --provider simulated \
  --model simulated-demo \
  --repo core=/path/to/core \
  --repo asm=/path/to/agent_session_manager \
  --default-repo core \
  --prompt-template from-adr
```

Why start with `simulated`? Because it lets you prove the packet shape and
verification contracts without requiring any external CLI or credentials.

Once the packet is solid, switch the provider to Codex, Claude, Gemini, or Amp.

## 2. Put Source Material Inside The Packet

Create a docs directory inside the packet:

```text
runtime-review/
  docs/
    adr-001-runtime-boundaries.md
    adr-002-recovery-contract.md
```

This keeps prompt references stable and reviewable.

## 3. Split Work Into Prompts

A good prompt boundary usually has:

- one primary output
- a clear repo target set
- a verification contract you can explain in one screen
- a commit message that makes sense on its own

Bad split:

- one giant prompt that edits many unrelated outputs

Good split:

- one prompt captures the architecture summary
- one prompt creates the execution checklist
- one prompt updates a specific implementation surface

## 4. Scaffold Prompts From A Template

```bash
mix prompt_runner prompt new 01 \
  --packet runtime-review \
  --phase 1 \
  --name "Capture runtime boundaries" \
  --targets core \
  --commit "docs: add runtime boundaries summary"
```

If the packet has `prompt_template: "from-adr"`, that template is used
automatically. Otherwise pass `--template`.

## 5. Fill In The Planning Metadata

Use these prompt keys:

- `references`
- `required_reading`
- `context_files`
- `depends_on`

Example:

```yaml
references:
  - "docs/adr-001-runtime-boundaries.md"
required_reading:
  - "docs/adr-001-runtime-boundaries.md"
context_files:
  - "workspace/README.md"
depends_on:
  - "01"
```

These keys are descriptive. They do not directly change runtime semantics, but
they make prompts self-describing and reviewable.

## 6. Translate Deliverables Into `verify:`

Do not stop at prose. Add a deterministic contract.

Typical pattern:

```yaml
verify:
  files_exist:
    - "RUNTIME_BOUNDARIES.md"
  contains:
    - path: "RUNTIME_BOUNDARIES.md"
      text: "Prompt Runner owns packet orchestration."
  changed_paths_only:
    - "RUNTIME_BOUNDARIES.md"
```

Use:

- `files_exist` for required outputs
- `contains` or `matches` for important content
- `commands` when repo-local checks are stronger than file inspection
- `changed_paths_only` to stop collateral edits

## 7. Generate Checklist Views

```bash
mix prompt_runner checklist sync runtime-review
```

Checklist files are for humans. The source of truth is still the verifier
contract plus `.prompt_runner/state.json`.

If a prompt has no verifier items yet, `checklist sync` warns loudly.

## 8. Use Doctor Before Run

```bash
mix prompt_runner packet doctor runtime-review
```

Doctor now flags common authoring gaps:

- no prompts
- no default repo
- prompt has no targets
- prompt has no verification items
- prompt still contains scaffold placeholder markers

## 9. Run And Iterate

```bash
mix prompt_runner list runtime-review
mix prompt_runner plan runtime-review
mix prompt_runner run runtime-review
mix prompt_runner status runtime-review
```

If verification fails after a nominal provider success, Prompt Runner can repair
the prompt automatically when recovery is enabled.

## 10. Move To A Real Provider

Once the packet structure is stable:

- switch profile/provider/model in `prompt_runner_packet.md`
- keep the same prompts, references, and `verify:` contracts
- rerun `packet doctor`, `plan`, and `run`

## Best Practices

- keep source docs inside the packet when possible
- make prompt boundaries correspond to reviewable outputs
- treat `verify:` as part of the prompt, not cleanup work
- use packet-local templates for shared team authoring patterns
- use the authoring example in `examples/authoring_packet/` as a reference
