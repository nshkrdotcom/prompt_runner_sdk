# Legacy Config Mode

Legacy mode is the explicit v0.4-style workflow. It remains fully supported.

Use it when you want:

- checked-in `prompts.txt`
- checked-in `commit-messages.txt`
- checked-in `runner_config.exs`
- per-prompt provider overrides via `prompt_overrides`
- exact control over progress and log file paths

## Required Files

- `runner_config.exs`
- `prompts.txt`
- `commit-messages.txt`
- prompt markdown files

## Example

`runner_config.exs`

```elixir
%{
  project_dir: "/path/to/repo",
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "haiku",
  llm: %{provider: "claude"}
}
```

`prompts.txt`

```text
01|1|3|Create hello file|001-hello.md
02|1|5|Add tests|002-tests.md
```

`commit-messages.txt`

```text
=== COMMIT 01 ===
feat: create hello file

=== COMMIT 02 ===
test: add coverage for hello flow
```

## Commands

```bash
mix run run_prompts.exs --config runner_config.exs --list
mix run run_prompts.exs --config runner_config.exs --validate
mix run run_prompts.exs --config runner_config.exs --run 01
mix run run_prompts.exs --config runner_config.exs --run --all
mix run run_prompts.exs --config runner_config.exs --run --continue
```

## Scaffold From Convention Mode

If you start with convention prompts but later want explicit files:

```bash
mix prompt_runner scaffold ./prompts --output ./generated --target /repo
```

The generated output is immediately usable in legacy mode.
