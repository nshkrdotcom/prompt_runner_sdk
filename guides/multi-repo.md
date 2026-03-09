# Multi-Repository Workflows

Prompt Runner supports multi-repo execution in both legacy and convention mode.

## Convention Mode

Use repeated named `--target` flags:

```bash
mix prompt_runner run ./prompts \
  --target app:/path/to/app \
  --target lib:/path/to/lib \
  --provider claude \
  --model haiku
```

Then target a prompt at one of those repos with front matter:

```markdown
---
targets: [app]
---
```

Or infer the repo from a path:

```markdown
## Repository Root

- `/path/to/app`
```

## Legacy Mode

Legacy config remains the richer multi-repo surface when you need:

- `repo_groups`
- per-repo commit messages
- explicit checked-in repo manifests

Example:

```elixir
%{
  project_dir: "/workspace",
  target_repos: [
    %{name: "frontend", path: "/path/to/frontend", default: true},
    %{name: "backend", path: "/path/to/backend"}
  ],
  repo_groups: %{
    "all" => ["frontend", "backend"]
  }
}
```

Prompt target column in `prompts.txt`:

```text
01|1|5|Setup both|001-setup.md|@all
```

Per-repo commit message markers:

```text
=== COMMIT 01:frontend ===
feat(frontend): initial setup

=== COMMIT 01:backend ===
feat(backend): initial setup
```

## Commit Behavior

- Convention/API mode defaults to `NoopCommitter` unless you opt into CLI or git-backed runs.
- CLI and legacy runs default to git commits.
- Multi-repo git commits are applied repo by repo after a successful prompt run.
