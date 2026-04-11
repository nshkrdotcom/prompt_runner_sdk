# CLI Guide

Prompt Runner exposes the same CLI through three entry points:

- `mix prompt_runner ...`
- `mix run run_prompts.exs -- ...`
- `./prompt_runner ...` after `mix escript.build`

All commands operate on a packet directory. If you omit the directory, Prompt
Runner uses the current working directory.

## Setup Commands

Initialize the global profile store:

```bash
mix prompt_runner init
mix prompt_runner template list
```

Create and inspect profiles:

```bash
mix prompt_runner profile new codex-fast --provider codex --model gpt-5.4 --reasoning high
mix prompt_runner profile list
```

## Packet Authoring Commands

Create a packet:

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

mix prompt_runner checklist sync demo
```

Packet-local templates can override the home-scoped templates created by
`init`. List visible templates for a packet with:

```bash
mix prompt_runner template list demo
```

Use the packet manifest's `recovery:` block for the full policy surface. The
CLI flags are convenience shorthands for common resume/retry/repair defaults.

Inspect packet metadata and runtime readiness:

```bash
mix prompt_runner packet explain demo
mix prompt_runner packet doctor demo
```

## Execution Commands

List and plan:

```bash
mix prompt_runner list demo
mix prompt_runner plan demo
```

Run everything:

```bash
mix prompt_runner run demo
```

Run specific prompts:

```bash
mix prompt_runner run demo 01 02
mix prompt_runner run demo --phase 2
```

Repair a failed prompt from stored verifier state:

```bash
mix prompt_runner repair --packet demo 02
```

Print runtime status JSON:

```bash
mix prompt_runner status demo
```

## Useful Execution Flags

`run` accepts:

- `--provider`
- `--model`
- `--log-mode`
- `--log-meta`
- `--events-mode`
- `--tool-output`
- `--cli-confirmation`
- `--runtime-store`
- `--committer`
- `--no-commit`

`packet new` accepts:

- `--repo NAME=PATH` (repeatable)
- `--default-repo`
- `--prompt-template`
- `--profile`
- `--provider`
- `--model`
- `--reasoning`
- `--permission`
- `--resume-attempts`
- `--retry-attempts`
- `--retry-base-delay-ms`
- `--retry-max-delay-ms`
- `--retry-jitter`
- `--auto-repair`
- `--repair-attempts`
- `--cli-confirmation`

`prompt new` accepts:

- `--packet`
- `--phase`
- `--name`
- `--targets`
- `--commit`
- `--template`

Example:

```bash
mix prompt_runner run demo \
  --provider codex \
  --model gpt-5.4 \
  --log-mode compact \
  --cli-confirmation require
```

## Escript

Build once:

```bash
mix escript.build
```

Then use the same commands:

```bash
./prompt_runner run demo
./prompt_runner status demo
```
