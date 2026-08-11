# Packet Linting

`mix prompt_runner packet lint` is the static authoring gate added in Prompt
Runner 0.10.0. It is the sibling of `packet doctor`, and the difference between
them is worth stating precisely:

- **`packet doctor` reports gaps.** A packet with no prompts, a packet with no
  default repo, a prompt with no targets, a prompt still full of scaffold
  placeholders. Things that are obviously unfinished.
- **`packet lint` reports hazards.** Constructs that load cleanly, run, and
  produce a wrong answer without ever raising.

Every check exists because a real packet hit it.

```bash
mix prompt_runner packet lint demo
mix prompt_runner packet lint demo --strict
mix prompt_runner packet lint demo --json
```

Exit status is `0` when only warnings remain and non-zero when any error is
present. `--strict` promotes every warning to an error, which is what you want
in CI.

## Errors

An error means the packet means something other than what it says. Fix it
before running.

### `prompt_id_filename_mismatch`

Prompts execute in the order of the numeric filename prefix — the sort key
built by `PromptRunner.Source.DirectorySource` — not in the order of the `id:`
in front matter. A prompt saved as `04_migrate.prompt.md` with `id: "07"`
runs fourth while every checklist, log line, and status entry calls it 07.

### `prompt_filename_without_prefix`

With no numeric prefix, a prompt sorts after every prefixed file, ordered by
basename against the other unprefixed ones. Name prompts `NN_name.prompt.md`.

### `duplicate_prompt_id`

Progress state, runtime state, and single-prompt selection (`run demo 04`) are
all keyed by id. Two prompts sharing one id overwrite each other's history.

### `unknown_target_repo`

A target that names no repo in the manifest contributes no working directory
and no verifier scope. The prompt still runs, in whatever `cwd` the remaining
targets resolve to.

### `unknown_verify_repo`

A verify entry scoped with `repo:` to a repository that does not exist resolves
against nothing. `packet` is always accepted — it is the alias for the packet
directory itself.

### `repo_group_in_targets`

`@group` syntax is a legacy-configuration feature. `PromptRunner.RepoTargets`
is never consulted with packet repo groups, so `targets: ["@core"]` expands to
nothing rather than to the group's members.

### `unknown_verify_clause`

An unrecognized key under `verify:` is parsed, stored, and never evaluated. A
contract with `file_exists:` (singular) reads like a gate and is not one. The
known clause list comes from `PromptRunner.Verifier.contract_keys/0`, so lint
and the verifier cannot drift.

### `verify_command_missing_path`

A `commands:` entry names a script that does not exist under the directory the
verifier will run it in — the entry's `repo:`, or the prompt's first target, or
the packet root. `bash -c` exits 127 for that, which the runner classifies as a
verifier fault and halts on. A contract kept pointing at `bin/check_doc.sh`
after those scripts moved one directory down; every clause exited 127 and a
finished prompt was discarded before that classification existed.

Detection is deliberately narrow. A token is checked only when it is
unambiguously a path this lint can resolve: it contains `/`, carries a script
suffix (`.sh`, `.exs`, `.ex`, `.py`, `.rb`, `.pl`, `.js`, `.ts`) or begins with
`./` or `../`, is not a URL, and contains no shell expansion, glob, or quote.
Everything else is left alone, because a check that guesses produces false
errors on correct packets and gets turned off.

## Warnings

A warning is usually wrong and occasionally deliberate. Warnings exit zero
unless `--strict` is given.

### `verify_command_without_timeout`

The verifier runs every command through `bash -c` with **no timeout**. A
command that hangs hangs the whole run, after the model work is already spent
and often after the session has already committed. Wrap commands:

```yaml
verify:
  commands:
    - "timeout 900 mix test"
    - repo: "app"
      run: "timeout 300 mix credo --strict"
```

Detection is deliberately shallow: a command counts as bounded when any of its
segments — split on `&&`, `||`, `;`, and `|` — begins with a `timeout` token.
Lint asserts that `timeout` is invoked, not that every branch of a compound
command is bounded. Deciding the latter needs a shell parser.

### `prompt_without_verify`

Without a contract, completion falls back to the provider's own claim of
success. That is the exact thing verifier-owned completion exists to replace.

### `contract_without_commands`

`files_exist` alone is satisfied by an empty file, so a contract built only
from `files_exist`, `files_absent`, and `changed_paths_only` cannot tell a
finished artifact from a touched one.

The check fires only when the contract has neither a `commands:` entry nor a
content assertion — `contains`, `matches`, or `doc`. A contract that asserts
content is not satisfiable by an empty file, so warning about it would be
false. If the deliverable is a document rather than code,
[`doc:`](verification-and-repair.md) is usually the clause you want.

### `changed_paths_only_vacuous`

`changed_paths_only` reads `git status --porcelain`, so it only ever sees work
that is **still uncommitted**.

It is the correct clause when the runner owns the commit — the default for CLI
packet runs — and it is worth keeping there.

It passes vacuously whenever the session commits its own work instead: under
`--no-commit`, under `committer: noop`, or under standing instructions that
tell the agent to commit. In all three cases the tree is already clean when the
verifier runs, so the clause cannot fail no matter what the session did. Use
[`repos_clean:`](verification-and-repair.md) for those packets.

This warning is unconditional. Lint cannot see how a packet is run, and a check
that only fires once someone has already declared `--no-commit` would stay
silent for exactly the packets most likely to have the problem — silence by
default is the failure mode the rest of this linter exists to remove. If the
runner commits for your packet, the message tells you so in one read and you
can ignore it.

Every packet under `examples/` trips this warning, and every one of them uses
the clause correctly: they are CLI packet runs, where the runner owns the
commit. That is the calibration to keep in mind — this is the one warning in
the set whose most common cause is a correct usage, which is why it stays a
warning and exits zero.

### `inert_front_matter_key`

`references`, `required_reading`, `context_files`, and `depends_on` are parsed
by `PromptRunner.Source.DirectorySource`, stored on `PromptRunner.Prompt`, and
then never read. They are never sent to the provider and never used for
ordering — only the markdown body after the front matter reaches the model, and
scheduling comes from the filename.

Write the paths into the prompt body:

```markdown
## Required Reading

- `/abs/path/docs/adr-001-runtime-boundaries.md`
- `/abs/path/docs/adr-002-verification.md`
```

Since 0.9.0 the built-in templates and `prompt new` no longer scaffold these
keys, so a freshly created packet lints clean.

## JSON Output

```bash
mix prompt_runner packet lint demo --json
```

```json
{
  "packet": "demo",
  "root": "/path/to/demo",
  "strict?": false,
  "no_commit?": false,
  "errors": 1,
  "warnings": 2,
  "pass?": false,
  "findings": [
    {
      "kind": "prompt_id_filename_mismatch",
      "severity": "error",
      "prompt_id": "07",
      "file": "04_migrate.prompt.md",
      "message": "prompt id \"07\" does not match the filename numeric prefix \"04\"; ..."
    }
  ]
}
```

## From Elixir

```elixir
{:ok, report} = PromptRunner.PacketLint.lint("/path/to/demo", strict: true)

report.pass?
report.findings
```

## Suggested Workflow

```bash
mix prompt_runner packet lint demo --strict   # authoring hazards
mix prompt_runner packet doctor demo          # authoring gaps
mix prompt_runner packet preflight demo       # runtime readiness
mix prompt_runner plan demo --provider codex  # resolved plan
mix prompt_runner run demo --dry-run          # per-prompt preview
mix prompt_runner run demo
```

`lint` and `doctor` are static. `preflight` touches the filesystem and git.
`plan` and `run --dry-run` resolve the actual execution plan. None of them
start a provider.
