# Multi-Repo Dummy Example

This example demonstrates a single prompt that targets two repositories
(alpha and beta) and writes a commit in each repo.

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

## 3) Run the prompt

```bash
mix run run_prompts.exs --config examples/multi_repo_dummy/runner_config.exs --list
mix run run_prompts.exs --config examples/multi_repo_dummy/runner_config.exs --run 01
```

After the run, you should see:
- `examples/multi_repo_dummy/repos/alpha/NOTES.md`
- `examples/multi_repo_dummy/repos/beta/NOTES.md`
- separate commits in each repo

## 4) Clean up

```bash
bash examples/multi_repo_dummy/cleanup.sh
```
