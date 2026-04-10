# Multi-Repository Packets

Multi-repo packets declare repos in the packet manifest and select them per
prompt through `targets`.

## Packet Manifest Example

```markdown
---
name: "multi-repo-demo"
provider: "codex"
model: "gpt-5.4"
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
