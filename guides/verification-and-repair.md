# Verification And Repair

Prompt Runner 0.9.0 treats deterministic verification as the source of truth
for prompt completion. A provider reporting success is evidence, not a verdict.

## Contract Keys

Supported checks:

| Clause | Asserts |
|--------|---------|
| `files_exist` | the path exists |
| `files_absent` | the path does not exist |
| `contains` | the file contains a literal substring |
| `matches` | the file matches a regular expression |
| `doc` | the document is substantive: line floor, required sections, no unresolved markers |
| `commands` | a shell command exits zero |
| `changed_paths_only` | `git status --porcelain` shows nothing outside an allowed set |
| `repos_clean` | the repository is committed, and optionally pushed |

Example:

```yaml
verify:
  files_exist:
    - "hello.txt"
  contains:
    - path: "hello.txt"
      text: "Hello from Prompt Runner"
  commands:
    - "timeout 60 test -s hello.txt"
```

Every clause supports repo scoping, either with a `repo:` key or by defaulting
to the prompt's first target. `packet` is always available as the alias for the
packet directory itself. See
[Multi-Repository Packets](multi-repo.md).

`mix prompt_runner packet lint` reports contracts whose shape makes them weaker
than they read — a command with no `timeout`, a contract with no `commands:`
entry, a typo'd clause name. See [Packet Linting](linting.md).

## `commands` Has No Timeout

The verifier runs every command through `bash -lc` with no timeout of its own.
A command that hangs hangs the whole run, after the model work is already spent.
Wrap every command:

```yaml
verify:
  commands:
    - "timeout 900 mix test"
    - repo: "app"
      run: "timeout 300 mix credo --strict"
```

This is not a style preference. A contract without it can cost a whole session.

## `doc` — Artifact Quality

`files_exist` is satisfied by a three-line stub. When the deliverable is a
written document, `doc:` is the clause that asserts it was actually written:

```yaml
verify:
  doc:
    - path: "docs/report.md"
      min_lines: 100
      requires_sections:
        - "## Method"
        - "## Verdict"
      forbids_markers:
        - "TODO"
        - "TBD"
        - "FIXME"
```

| Key | Default | Meaning |
|-----|---------|---------|
| `path` | required | document path, repo-scoped like every other clause |
| `repo` | prompt's default scope | repository the path resolves against |
| `min_lines` | `1` | minimum **non-blank** lines |
| `requires_sections` | `[]` | verbatim substrings that must be present |
| `forbids_markers` | `["TODO", "TBD", "FIXME", "XXX"]` | substrings that must be absent |

`requires_sections` matches verbatim, so heading level and wording are both
asserted. `forbids_markers` **replaces** the default set rather than extending
it, and an explicit `forbids_markers: []` disables the check — use that for a
document whose subject is authoring markers.

A bare string entry uses every default:

```yaml
verify:
  doc:
    - "docs/report.md"     # exists, has at least one non-blank line, no markers
```

The `details:` string names what is wrong, because a repair session reads it:

```text
42 non-blank lines, needs 100; missing sections: ## Verdict; forbidden markers: TODO (line 12)
```

## `repos_clean` — Sessions Committed Their Work

```yaml
verify:
  repos_clean:
    - repo: "app"
    - repo: "docs"
      pushed: true
```

| Key | Default | Meaning |
|-----|---------|---------|
| `repo` | prompt's default scope | repository to check |
| `pushed` | `false` | also require an upstream, and require `HEAD` to match it |
| `remote_timeout_ms` | `90000` | bound on the remote query |

`pushed: false` checks only that the working tree is clean. A branch with no
upstream is fine — a repository that starts local and stays local until its
author decides to publish it must not fail a gate for that — and an existing
upstream is not compared.

`pushed: true` additionally **requires** an upstream. A missing upstream is a
failure, not a pass: the clause was asked to assert publication and cannot.

The comparison asks the remote directly with `git ls-remote`, under a bounded
timeout. `ls-remote` is a pure query — unlike `git fetch` it does not create or
move remote-tracking refs — so this clause writes nothing at all into the
repository it is judging. A gate that mutates any part of its subject is a gate
that can change the thing it measures.

When the remote cannot be reached, `details:` says so and the comparison falls
back to the cached remote-tracking ref. That fallback is biased toward
reporting *not pushed*, since a cached ref can only be behind the remote and
never ahead of it, which is the safe direction for a clause whose job is to
assert publication.

### `changed_paths_only` vs `repos_clean`

They answer opposite questions and are usually mutually exclusive.

`changed_paths_only` reads `git status --porcelain` and asserts that nothing
outside an allowed set is *uncommitted*. It is the right clause when the runner
owns the commit.

Under `--no-commit`, each session commits its own work, so the tree is clean
when the verifier runs and `changed_paths_only` passes vacuously — it can never
fail. The same is true under `committer: noop`, and under standing instructions
that tell the agent to commit. `repos_clean` is the clause for those
arrangements. `mix prompt_runner packet lint` warns on every use of
`changed_paths_only`, because it cannot see which arrangement you are in; the
message names the condition under which the clause is still correct.

## Outcome Matrix

After each attempt, Prompt Runner combines the provider outcome with the
verifier report:

- provider success + verifier pass => complete
- provider success + verifier fail => repair, while the repair budget lasts
- provider failure + verifier pass => complete unless the failure is a local
  deterministic contradiction such as CLI confirmation mismatch
- remote/provider-claimed auth, config, model-unavailable, capacity, and
  generic runtime failures => bounded retries by policy
- provider failure + verifier fail + partial workspace progress => repair
- retry exhaustion + partial workspace progress => repair
- verifier fail with the repair budget spent, repair disabled, or the attempt
  already a repair => **fail**
- local deterministic failure => fail

That second-to-last line is load-bearing. Repair is bounded by
`recovery.repair.max_attempts`, and when the budget is gone the run fails and
reports the unmet items:

```text
ERROR: verification failed: file_exists docs/report.md: missing
```

## Retry, Resume, And Repair

Retry is for remote/provider-claimed failures that may be flaky or mislabeled,
including auth, config, model-unavailable, capacity, and generic runtime
claims.

Resume is the first recovery step for recoverable transport/protocol failures.

Repair is for semantic incompletion or partial workspace progress. Prompt
Runner synthesizes a repair prompt from the unmet verifier items rather than
blindly replaying the original instruction: it appends a `## Repair
Instructions` block carrying the last error and the remaining failures to the
prompt body. **This is why `details:` must be diagnostic rather than boolean —
those strings are what the repair session reads.**

Packet-level recovery defaults live in `prompt_runner_packet.md`, and a prompt
can tighten or relax them with its own front-matter `recovery:` block.

## Checklist Views

```bash
mix prompt_runner checklist sync /path/to/packet
```

Every clause, including `doc:` and `repos_clean:`, renders into the generated
checklist. Those files are for human navigation; the verifier report remains
the actual completion source of truth.

## Deterministic Recovery Demos

Use the built-in `simulated` provider to prove retry, repair, or resume
behavior without relying on a real provider outage.

The shipped simulated packet covers successful recovery for:

- provider capacity
- provider rate limits
- remote auth claims
- remote config/model-unavailable claims
- late remote runtime errors after correct output
- retry exhaustion followed by repair
- protocol disconnect resume
- transport-timeout resume

Terminal remote claims such as approval denial, guardrail blocks, and explicit
user cancellation are covered in the automated test suite so the example pack
remains a clean, fully successful walkthrough.

See:

- `examples/simulated_recovery_packet/`
- [Simulated Provider](simulated-provider.md)

## Runtime State

Packet-local state is stored in:

```text
.prompt_runner/state.json
```

It records:

- prompt status
- attempt history, with the mode of each attempt (`run`, `retry`, `repair`)
- verifier results
- failure class
- repair/retry progression

Run `mix prompt_runner status <packet>` to print it.
