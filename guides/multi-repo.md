# Multi-Repository Packets

Multi-repo packets declare repos in the packet manifest and select them per
prompt through `targets`.

## Packet Manifest Example

```markdown
---
name: "multi-repo-demo"
provider: "codex"
model: "gpt-5.6-luna"
reasoning_effort: "xhigh"
permission_mode: "bypass"
codex_thread_opts:
  additional_directories:
    - "./repos/beta"
repos:
  alpha:
    path: "./repos/alpha"
    default: true
  beta:
    path: "./repos/beta"
---
# Multi Repo Demo
```

## Prompt Targeting

Target both repos:

```yaml
targets:
  - "alpha"
  - "beta"
```

Or target one repo but still make a sibling repo available to Codex through
packet-level `codex_thread_opts.additional_directories`.

## Repo-Scoped Verification

Verification entries can be scoped to a specific repo:

```yaml
verify:
  files_exist:
    - repo: "alpha"
      path: "NOTES.md"
    - repo: "beta"
      path: "NOTES.md"
  changed_paths_only:
    - repo: "alpha"
      path: "NOTES.md"
    - repo: "beta"
      path: "NOTES.md"
```

That keeps multi-repo prompts deterministic and makes stray file creation show
up as a verifier failure.

## Commit Behavior

CLI packet runs default to git commits. Multi-repo commits are applied repo by
repo after verification passes.

API runs default to a no-op committer unless you opt into git.

### When Sessions Own Their Commits

The built-in committer squashes a multi-repository change under one generated
message and never pushes. For a packet whose standing orders make each session
commit its own work across several repositories, run with `--no-commit` and
gate on the result instead:

```yaml
verify:
  repos_clean:
    - repo: "alpha"
      pushed: true
    - repo: "beta"
```

Under `--no-commit`, `changed_paths_only` passes vacuously — it reads
`git status --porcelain`, which is empty precisely because the session already
committed. `mix prompt_runner packet lint` warns about every use of the clause
for that reason. See [Verification And Repair](verification-and-repair.md).
