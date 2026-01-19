# Multi-Repo Dummy Example

This example demonstrates two prompts that target the same two repositories
(alpha and beta) and write a commit in each repo:

- Prompt 01 runs with `codex_sdk`.
- Prompt 02 runs with `claude_agent_sdk` and only allows the Bash tool to write the files.

## 1) Create the dummy repos

Run the setup script. It creates two git repos under `examples/multi_repo_dummy/repos`.

```bash
cd /home/home/p/g/n/prompt_runner_sdk
bash examples/multi_repo_dummy/setup.sh
```

## 2) Inspect the config

```bash
cat examples/multi_repo_dummy/runner_config.exs
cat examples/multi_repo_dummy/prompts.txt
cat examples/multi_repo_dummy/commit-messages.txt
```

## 3) Run the prompts

```bash
mix run run_prompts.exs --config examples/multi_repo_dummy/runner_config.exs --list
mix run run_prompts.exs --config examples/multi_repo_dummy/runner_config.exs --run 01
mix run run_prompts.exs --config examples/multi_repo_dummy/runner_config.exs --run 02
```

After each run, you should see:
- `examples/multi_repo_dummy/repos/alpha/NOTES.md`
- `examples/multi_repo_dummy/repos/beta/NOTES.md`
- separate commits in each repo

## 4) Clean up

```bash
bash examples/multi_repo_dummy/cleanup.sh
```
