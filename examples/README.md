# Examples

Two examples covering the two use cases:

| Example | Use Case | What It Shows |
|---------|----------|---------------|
| `simple/` | Single repo | Four-provider execution in one repo (Claude, Codex, Amp, Gemini) |
| `multi_repo_dummy/` | Multiple repos | Per-repo targeting and commits across Claude, Codex, Amp, and Gemini |

## simple/

Single repository workflow. Four prompts write files to the same repo:
- Prompt 01: Claude
- Prompt 02: Codex
- Prompt 03: Amp
- Prompt 04: Gemini

From the project root:

```bash
bash examples/simple/setup.sh
mix run run_prompts.exs -c examples/simple/runner_config.exs --list
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 01
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 02
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 03
mix run run_prompts.exs -c examples/simple/runner_config.exs --run 04
bash examples/simple/cleanup.sh
```

## multi_repo_dummy/

Multi-repository workflow. Four prompts target two repos (alpha, beta):
- Prompt 01: Codex, targets both repos
- Prompt 02: Claude, targets both repos
- Prompt 03: Amp, targets both repos
- Prompt 04: Gemini, targets both repos

From the project root:

```bash
bash examples/multi_repo_dummy/setup.sh
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --list
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 01
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 02
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 03
mix run run_prompts.exs -c examples/multi_repo_dummy/runner_config.exs --run 04
bash examples/multi_repo_dummy/cleanup.sh
```

## Which to Start With?

- **Most users:** Start with `simple/` - it's the common case
- **Cross-repo workflows:** Use `multi_repo_dummy/` as your reference

## Recovery-Oriented Example Packs

The example packs in this repo are now the primary manual proof surface for Prompt Runner’s
resume-first recovery posture:

- `examples/simple/` exercises the single-repo provider matrix
- `examples/multi_repo_dummy/` exercises multi-repo prompt planning and execution boundaries

Both example packs now rely on the current ASM session runtime, so provider-native recovery handles
can flow through normal prompt execution.

Both standalone example runners install the local `prompt_runner_sdk` checkout
plus `agent_session_manager`; provider selection and CLI execution still flow
through ASM core lane, with no provider SDK packages.

Both `setup.sh` scripts reset and reseed their example workspace, so rerunning
them gives you a clean starting state.
