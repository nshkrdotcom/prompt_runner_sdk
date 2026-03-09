# Convention Mode

Convention mode lets you run prompts from a directory without authoring
`prompts.txt` or `commit-messages.txt`.

## File Discovery

Prompt Runner looks for:

1. `*.prompt.md`
2. `*.md` if no `.prompt.md` files exist

Files are sorted by their leading numeric prefix.

Examples:

- `01_auth.prompt.md`
- `02_tests.prompt.md`
- `10_release.prompt.md`

## Supported Metadata

### Front matter

```markdown
---
num: 02
phase: 2
sp: 5
targets: [app]
commit: "test: harden auth flows"
validation:
  - mix test
  - mix compile --warnings-as-errors
---
```

### Heading fallbacks

The loader also understands:

- `# Heading` for the prompt name
- `## Mission` for synthesized commit messages
- `## Validation Commands` for validation command extraction
- `## Repository Root` for path-based target inference

## Example Prompt

```markdown
# Reconcile auth ownership

## Mission

Align the auth architecture across code and docs.

## Validation Commands

- `mix test`
```

## Targets

You can target repositories in three ways:

### Single repo via CLI

```bash
mix prompt_runner run ./prompts --target /path/to/repo
```

### Named targets via repeated flags

```bash
mix prompt_runner run ./prompts \
  --target app:/path/to/app \
  --target lib:/path/to/lib
```

### In-file targets

```markdown
---
targets: [app]
---
```

Or:

```markdown
## Repository Root

- `/path/to/app`
```

## Runtime State

CLI convention mode writes runtime state to:

```text
<prompt_dir>/.prompt_runner/
```

API convention mode defaults to in-memory runtime state and no git commits.

## When To Use Convention Mode

Use it when you want:

- minimal setup
- prompt directories that live next to design docs
- API-driven or ad hoc runs
- optional scaffolding into explicit files later
