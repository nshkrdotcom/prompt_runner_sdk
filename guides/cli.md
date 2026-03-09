# CLI Guide

Prompt Runner exposes three CLI entrypoints:

- `mix prompt_runner ...`
- `./prompt_runner ...` after `mix escript.build`
- `mix run run_prompts.exs --config ...` for legacy mode

## Convention Commands

```bash
mix prompt_runner list ./prompts --target /repo
mix prompt_runner plan ./prompts --target /repo
mix prompt_runner validate ./prompts --target /repo
mix prompt_runner run ./prompts --target /repo
mix prompt_runner scaffold ./prompts --output ./generated --target /repo
```

## Common Flags

| Flag | Meaning |
|------|---------|
| `--target /path` | Single default target repo |
| `--target name:/path` | Named target repo, repeatable |
| `--provider claude|codex|amp` | Provider selection |
| `--model MODEL` | Model name |
| `--output DIR` | Scaffold output directory |
| `--state-dir DIR` | Override the CLI runtime state directory |
| `--no-state` | Disable file-backed runtime state |
| `--runtime-store file|memory|noop` | Select the runtime store |
| `--committer git|noop` | Select the post-run committer |
| `--log-mode compact|verbose|studio` | Renderer mode |
| `--log-meta none|full` | Failure detail mode |
| `--events-mode compact|full|off` | JSONL event log mode |
| `--tool-output summary|preview|full` | Studio tool output verbosity |

## Legacy Mode

Legacy mode is still available and still requires `--config`:

```bash
mix run run_prompts.exs --config runner_config.exs --list
mix run run_prompts.exs --config runner_config.exs --run 01
mix run run_prompts.exs --config runner_config.exs --run --all
mix run run_prompts.exs --config runner_config.exs --validate
```

## Escript

Build once:

```bash
mix escript.build
```

Use anywhere with Erlang/OTP available:

```bash
./prompt_runner run ./prompts --target /repo --provider claude --model haiku
```

## Scaffold Command

`scaffold` converts convention prompts into explicit legacy files:

```bash
mix prompt_runner scaffold ./prompts --output ./generated --target /repo
```

Generated artifacts:

- `prompts.txt`
- `commit-messages.txt`
- `runner_config.exs`
- `run_prompts.exs`
