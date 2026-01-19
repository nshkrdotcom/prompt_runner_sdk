# Examples

This directory contains runnable examples for Prompt Runner SDK.
Each example has its own README with setup and run steps.

## Examples

- `simple/` - Two prompts that write files: one via Claude Agent SDK, one via Codex SDK.
- `multi_repo_dummy/` - Two prompts that target two dummy repos and commit in each repo.

## Quick start

```bash
cd /home/home/p/g/n/prompt_runner_sdk

# Simple example
bash -lc "cd examples/simple && cat README.md"

# Multi-repo example
bash -lc "cd examples/multi_repo_dummy && cat README.md"
```
