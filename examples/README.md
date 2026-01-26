# Examples

Two examples covering the two use cases:

| Example | Use Case | What It Shows |
|---------|----------|---------------|
| `simple/` | Single repo | Dual LLM support (Claude + Codex) |
| `multi_repo_dummy/` | Multiple repos | Per-repo targeting and commits |

## simple/

Single repository workflow. Two prompts write files to the same repo:
- Prompt 01: Claude Agent SDK
- Prompt 02: Codex SDK

```bash
cd /home/home/p/g/n/prompt_runner_sdk
mix run run_prompts.exs -c examples/simple/runner_config.exs --list
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 01
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 02
```

## multi_repo_dummy/

Multi-repository workflow. Two prompts target two repos (alpha, beta):
- Prompt 01: Codex SDK, targets both repos
- Prompt 02: Claude Agent SDK, targets both repos

```bash
cd /home/home/p/g/n/prompt_runner_sdk
bash examples/multi_repo_dummy/setup.sh
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --list
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 01
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 02
bash examples/multi_repo_dummy/cleanup.sh
```

## Which to Start With?

- **Most users:** Start with `simple/` - it's the common case
- **Cross-repo workflows:** Use `multi_repo_dummy/` as your reference
