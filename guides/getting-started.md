# Getting Started

Prompt Runner SDK supports two starting points:

- Convention mode: point the runner at a directory of `.prompt.md` files.
- Legacy mode: keep explicit `runner_config.exs`, `prompts.txt`, and `commit-messages.txt`.

For new projects, start with convention mode.
This guide targets `prompt_runner_sdk ~> 0.6.0`.

## Install

```elixir
def deps do
  [
    {:prompt_runner_sdk, "~> 0.6.0"}
  ]
end
```

Fetch dependencies:

```bash
mix deps.get
```

## Provider Credentials

Set the provider CLI credentials your chosen provider expects:

| Provider | Env Var |
|----------|---------|
| Claude | `ANTHROPIC_API_KEY` |
| Codex | `OPENAI_API_KEY` |
| Gemini | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Amp | `AMP_API_KEY` |

## First Convention Run

Create `prompts/01_hello.prompt.md`:

```markdown
# Create hello.txt

## Mission

Create `hello.txt` with the text `Hello from PromptRunner`.
```

Run it:

```bash
mix prompt_runner run ./prompts --target /path/to/repo --provider claude --model haiku
```

Useful companion commands:

```bash
mix prompt_runner list ./prompts --target /path/to/repo
mix prompt_runner plan ./prompts --target /path/to/repo
mix prompt_runner validate ./prompts --target /path/to/repo
```

## What Gets Created

CLI convention runs create:

```text
prompts/
  01_hello.prompt.md
  .prompt_runner/
    progress.log
    logs/
```

API runs do not create this state by default.

## First API Run

```elixir
{:ok, run} =
  PromptRunner.run("./prompts",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

Or run one ad hoc prompt:

```elixir
{:ok, run} =
  PromptRunner.run_prompt(
    "Create hello.txt with the text Hello from PromptRunner.",
    target: "/path/to/repo",
    provider: :claude,
    model: "haiku"
  )
```

## If You Need Explicit Files

Generate the legacy files from a prompt directory:

```bash
mix prompt_runner scaffold ./prompts --output ./generated --target /path/to/repo
```

That writes:

- `prompts.txt`
- `commit-messages.txt`
- `runner_config.exs`
- `run_prompts.exs`

## Next Steps

- [Convention Mode](convention-mode.md)
- [CLI Guide](cli.md)
- [API Guide](api.md)
- [Configuration Reference](configuration.md)
- [Legacy Config Mode](legacy-config.md)
