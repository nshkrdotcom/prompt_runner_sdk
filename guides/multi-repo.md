# Multi-Repository Workflows

Prompt Runner SDK can orchestrate prompts across multiple git repositories, creating separate commits in each.

## When to Use Multi-Repo

Use `target_repos` when your prompts modify code in separate git repositories:
- A frontend and backend that need coordinated changes
- A library and its consumers
- Multiple microservices

If all your code is in one repo, skip `target_repos` entirely — the SDK defaults to single-repo mode using `project_dir`.

## Configuration

### target_repos

Define your repositories:

```elixir
%{
  project_dir: "/path/to/workspace",
  target_repos: [
    %{name: "frontend", path: "/path/to/frontend", default: true},
    %{name: "backend", path: "/path/to/backend"}
  ],
  prompts_file: "prompts.txt",
  commit_messages_file: "commit-messages.txt",
  progress_file: ".progress",
  log_dir: "logs",
  model: "haiku",
  llm: %{provider: "claude"}
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Short name used in prompts.txt and commit message markers. |
| `path` | yes | Absolute path to the git repository. |
| `default` | no | If `true`, prompts without explicit `TARGET_REPOS` target this repo. |

`project_dir` is used as the LLM's working directory (`cwd`), which can be different from any individual repo path.

### repo_groups

Define named groups to avoid repeating repo lists:

```elixir
%{
  repo_groups: %{
    "all" => ["frontend", "backend", "shared"],
    "services" => ["frontend", "backend"],
    "nested" => ["@services", "shared"]
  },
  target_repos: [
    %{name: "frontend", path: "/path/to/frontend"},
    %{name: "backend", path: "/path/to/backend"},
    %{name: "shared", path: "/path/to/shared"}
  ]
}
```

Groups can reference other groups with `@`:
- `"@services"` expands to `["frontend", "backend"]`
- `"@nested"` expands to `["frontend", "backend", "shared"]`

Duplicates are removed. Cycles are detected and reported as errors.

Group expansion is handled by `PromptRunner.RepoTargets`.

## Prompts File

Add the `TARGET_REPOS` column (6th pipe-delimited field) to specify which repos each prompt targets:

```
01|1|5|Setup both|001-setup.md|frontend,backend
02|1|8|Frontend only|002-frontend.md|frontend
03|1|8|Backend only|003-backend.md|backend
04|1|3|Everything|004-all.md|@all
```

- Comma-separated repo names: `frontend,backend`
- Group references: `@all`, `@services`
- Mixed: `frontend,@services` (duplicates are removed)
- Omitted: targets the `default: true` repo (or the first repo if none is marked default)

## Commit Messages

Use repo-qualified markers in your commit messages file:

```
=== COMMIT 01:frontend ===
feat(frontend): initial database setup

=== COMMIT 01:backend ===
feat(backend): initial API scaffold

=== COMMIT 02:frontend ===
feat(frontend): add React components

=== COMMIT 03:backend ===
feat(backend): add API routes
```

The marker format is `=== COMMIT NN:repo_name ===`.

For each repo targeted by a prompt, the SDK looks for `NN:repo_name` first, then falls back to a generic `NN` marker (without repo qualifier). This lets you use a single message when the commit text is the same across repos.

### Validation

`--validate` checks that every prompt/repo combination has a matching commit message:

```bash
mix run run_prompts.exs -c runner_config.exs --validate
```

## Commit Behavior

When a prompt targets multiple repos:

1. The LLM runs once with `project_dir` as its working directory
2. After the LLM completes, `Git.commit_multi_repo/3` iterates over each target repo
3. Each repo gets a separate `git add -A && git commit` with its own message
4. The progress file records all commit SHAs: `01:completed:TIMESTAMP:frontend=abc1234,backend=def5678`

If a repo has no changes after the prompt runs, it records `no_changes` for that repo.

## CLI Overrides

Override repo paths at runtime without changing the config file:

```bash
mix run run_prompts.exs -c config.exs --run 01 \
  --repo-override frontend:/tmp/test-frontend \
  --repo-override backend:/tmp/test-backend
```

The `--repo-override` flag is repeatable and takes the form `name:path`.

## Example

The `examples/multi_repo_dummy/` directory provides a working example:

```bash
# 1. Create dummy git repos (alpha and beta)
bash examples/multi_repo_dummy/setup.sh

# 2. List prompts
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --list

# 3. Run prompt 01 (Codex provider, targets both repos)
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 01

# 4. Run prompt 02 (Claude provider, targets both repos, restricted tools)
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 02
```

This example demonstrates:
- Two repos (`alpha`, `beta`) with per-repo commits
- Default provider `codex` with prompt 02 overriding to `claude`
- Tool restrictions on prompt 02 (`allowed_tools: ["Bash"]`, `permission_mode: :dangerously_skip_permissions`)

## Cleanup

```bash
bash examples/multi_repo_dummy/teardown.sh
```
