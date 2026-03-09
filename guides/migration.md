# Migration Notes

## v0.4 to v0.5

v0.5 adds convention mode and a real public API without removing legacy mode.

## What Stays The Same

- `runner_config.exs` still works.
- `prompts.txt` still works.
- `commit-messages.txt` still works.
- `run_prompts.exs` still works.
- multi-repo commits still work.

## What Is New

- `PromptRunner.run/2`
- `PromptRunner.plan/2`
- `PromptRunner.validate/2`
- `PromptRunner.run_prompt/2`
- `mix prompt_runner ...`
- directory-based convention loading
- CLI state in `.prompt_runner/`
- scaffold generation from convention prompts

## Recommended Upgrade Path

### If you already use legacy config

Keep it.

Only adopt convention mode if it removes real workflow friction.

### If you are starting fresh

Use convention mode first:

```bash
mix prompt_runner run ./prompts --target /repo
```

Generate explicit files later only if you need them:

```bash
mix prompt_runner scaffold ./prompts --output ./generated --target /repo
```

## Embedded Production Use

Do not rely on Mix in production code.

Use:

- `PromptRunner.run/2`
- `PromptRunner.plan/2`
- `PromptRunner.run_prompt/2`

Use the CLI or Mix task for local developer workflows.
