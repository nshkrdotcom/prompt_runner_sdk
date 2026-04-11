# Authoring From ADRs Packet

This example is the onboarding path for users who already have design docs or
ADRs but do not yet have finished prompts.

It demonstrates:

- packet-local source material under `docs/`
- a packet-local prompt template under `templates/`
- prompt metadata for `references`, `required_reading`, `context_files`, and
  `depends_on`
- deterministic `verify:` contracts and generated checklist files
- a runnable packet using the built-in `simulated` provider

## Structure

Inspect these first:

- `prompt_runner_packet.md`
- `templates/from-adr.prompt.md`
- `docs/adr-001-runtime-boundaries.md`
- `docs/adr-002-recovery-contract.md`
- `prompts/01_capture_runtime_boundaries.prompt.md`
- `prompts/02_create_execution_checklist.prompt.md`

## What This Example Teaches

The workflow is:

1. collect the source docs inside the packet
2. choose a prompt template
3. create prompts with explicit `required_reading`
4. translate deliverables into `verify:` entries
5. generate checklist views
6. run and inspect packet-local state

## Run It

From the project root:

```bash
bash examples/authoring_packet/setup.sh
mix prompt_runner list examples/authoring_packet
mix prompt_runner packet doctor examples/authoring_packet
mix prompt_runner checklist sync examples/authoring_packet
mix prompt_runner run examples/authoring_packet
mix prompt_runner status examples/authoring_packet
bash examples/authoring_packet/cleanup.sh
```

## Expected Outputs

After a successful run:

- `workspace/RUNTIME_BOUNDARIES.md`
- `workspace/EXECUTION_CHECKLIST.md`

The packet-local runtime state is written to:

- `.prompt_runner/state.json`
- `.prompt_runner/logs/`

## Why It Exists

The other shipped examples show finished runnable packets. This one shows the
missing authoring step: how to turn source docs into prompt files with explicit
reading lists, dependencies, and verification contracts.
