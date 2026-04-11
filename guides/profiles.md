# Profiles

Profiles are home-scoped defaults stored under:

```text
~/.config/prompt_runner/
  config.md
  profiles/
    codex-default.md
    simulated-default.md
```

## Initialize

```bash
mix prompt_runner init
```

That creates:

- `config.md`
- `profiles/codex-default.md`
- `profiles/simulated-default.md`

## Default Profile

`codex-default` is optimized for local packet work:

- `provider: codex`
- `model: gpt-5.4`
- `reasoning_effort: xhigh`
- `permission_mode: bypass`
- `allowed_tools: Read, Edit, Write, Bash`
- `cli_confirmation: require`
- `recovery.resume_attempts: 2`
- `recovery.retry.max_attempts: 3`
- `recovery.repair.enabled: true`

## Create Another Profile

```bash
mix prompt_runner profile new claude-safe \
  --provider claude \
  --model sonnet \
  --permission default \
  --tools Read,Bash
```

## Precedence

The intended authoring precedence is:

1. profile defaults
2. packet manifest values
3. prompt front matter overrides
4. explicit CLI or API options

Use profiles for standing preferences, packets for team-shared defaults, and
prompt front matter only when a prompt genuinely needs a local override.

## Simulated Demo Profile

`simulated-default` is optimized for recovery demos and tests:

- `provider: simulated`
- `model: simulated-demo`
- `reasoning_effort: low`
- `permission_mode: bypass`
- `cli_confirmation: off`
- `recovery.resume_attempts: 2`
- `recovery.retry.base_delay_ms: 0`
- `recovery.retry.max_delay_ms: 0`
- `recovery.repair.enabled: true`
