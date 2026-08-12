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

Once the packet is solid, switch the provider to Codex, Claude, Amp, Cursor,
or Antigravity.

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

## 5. Write The Source Material Into The Body

Put every path a mission must read into the prompt body, under
`## Required Reading`:

```markdown
## Required Reading

- `docs/adr-001-runtime-boundaries.md`
- `docs/adr-002-verification.md`
```

Use absolute paths when the prompt spans repositories — the session's working
directory is the first entry in `targets:`.

Front-matter `references`, `required_reading`, and `context_files` look like the
natural home for this and are not. They are parsed and stored but never sent to
the provider. Only the markdown body reaches the model.

`depends_on` is real scheduler input and controls ordering/blocking, but it does
not explain the dependency to the model. Put that explanation and any required
reading in the body.

`mix prompt_runner packet lint` reports any prompt still carrying them.

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
  commands:
    - "timeout 120 test -s RUNTIME_BOUNDARIES.md"
  changed_paths_only:
    - "RUNTIME_BOUNDARIES.md"
```

Use:

- `files_exist` for required outputs
- `contains` or `matches` for important content
- `doc` when the deliverable is a written document and `files_exist` would be
  satisfied by a stub
- `commands` when repo-local checks are stronger than file inspection, always
  wrapped in `timeout`
- `changed_paths_only` to stop collateral edits when the runner owns the commit
- `repos_clean` instead, when the packet runs with `--no-commit` and each
  session commits its own work

See [Verification And Repair](verification-and-repair.md) for the full clause
reference.

## 7. Generate Checklist Views

```bash
mix prompt_runner checklist sync runtime-review
```

Checklist files are for humans. The source of truth is still the verifier
contract plus `.prompt_runner/state.json`.

If a prompt has no verifier items yet, `checklist sync` warns loudly.

## 8. Lint, Doctor, And Preflight Before Run

```bash
mix prompt_runner packet lint runtime-review --strict
mix prompt_runner packet doctor runtime-review
mix prompt_runner packet preflight runtime-review
```

Lint reports authoring hazards — an id that does not match its filename prefix,
a verify command with no `timeout`, a target naming a repo that does not exist,
a typo'd verify clause. All of those load and run and quietly mean something
else. See [Packet Linting](linting.md).

Doctor flags authoring gaps:

- no prompts
- no default repo
- prompt has no targets
- prompt has no verification items
- prompt still contains scaffold placeholder markers

Preflight is the runtime gate that checks packet-local repo paths and git
readiness, and `run` calls it automatically.

## 9. Run And Iterate

```bash
mix prompt_runner list runtime-review
mix prompt_runner plan runtime-review
mix prompt_runner run runtime-review --dry-run
mix prompt_runner run runtime-review
mix prompt_runner status runtime-review
```

If verification fails after a nominal provider success, Prompt Runner repairs
the prompt automatically while the repair budget lasts, then fails with the
unmet verifier items.

## 10. Move To A Real Provider

Once the packet structure is stable:

- switch profile/provider/model in `prompt_runner_packet.md`
- keep the same prompts, source material, and `verify:` contracts
- verify the override does what you expect with
  `mix prompt_runner plan runtime-review --provider codex`
- rerun `packet lint`, `packet doctor`, `packet preflight`, `plan`, and `run`
- for a long run, supervise it with `mix prompt_runner watch runtime-review`

## Best Practices

- keep source docs inside the packet when possible
- write every path a mission must read into the prompt body, not into inert
  front-matter keys
- make prompt boundaries correspond to reviewable outputs
- treat `verify:` as part of the prompt, not cleanup work
- in verifier-owned packets, use structured `verify.commands` with
  `timeout_ms`; in agent-owned packets, put executable QC in the prompt and use
  prompt-specific structural verification
- use packet-local templates for shared team authoring patterns
- use the authoring example in `examples/authoring_packet/` as a reference
