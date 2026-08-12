# Operator Workspaces

Prompt Runner 0.12.1 replaces packet-specific shell orchestration with a strict
workspace manifest and an installed escript. A workspace gives one operator
full independent clones, ordinary in-clone `_build` and `deps`, external runtime
state, installed contract artifacts, and cgroup-backed process containment.

## Lifecycle

```bash
prompt_runner workspace plan workspace.yml
prompt_runner workspace prepare workspace.yml
prompt_runner workspace doctor workspace.yml
prompt_runner packet lint packet --strict
prompt_runner workspace import-state workspace.yml packet
prompt_runner verify operator-packet 01
prompt_runner plan operator-packet --remaining
prompt_runner start operator-packet --remaining --no-commit
prompt_runner status operator-packet
prompt_runner control status operator-packet --json
prompt_runner control events operator-packet
prompt_runner control log operator-packet --follow # operator requests only
prompt_runner watch operator-packet --for 240m --every 10m \
  --require-running --require-progress --progress-timeout 60m
prompt_runner stop operator-packet
```

If a reviewed packet upgrade intentionally changes the content fingerprint of
a failed or interrupted run, add `--new-run` to `start`. This preserves the old
append-only journal and completed-prompt progress while creating a fresh run
identity. A fingerprint mismatch without explicit supersession still fails
closed.

`prepare` is the only materializing operation. It clones without hardlinks or
Git alternates, refuses dirty existing clones, fast-forwards only, and builds
declared contract escripts into the operator's workspace. It also registers the
workspace id and lock location in versioned operator-owned XDG data, including
when the manifest selects custom workspace roots. That small reference is what
makes the id an ergonomic address; project files and shell configuration remain
untouched. `doctor` is read-only:
it probes exact `.tool-versions` from their project directories and never runs
Mix or a login shell. Dirty clones are reported as resumable work, since a crash
must not make unfinished work impossible to resume.

`import-state` is an explicit, one-time bridge from a packet-local legacy
`.prompt_runner/progress.log` into an empty operator runtime. It validates the
records against the current packet, imports only the latest `completed` status
for each prompt, refuses an active run or existing destination progress, and
writes a digest-bearing receipt. Failed and running legacy work is never marked
complete. Use `--source PROGRESS_FILE` when the old state is elsewhere.

`start` launches the installed `prompt_runner` executable as a transient
`systemd --user` service with `KillMode=control-group`. Environment names are
inherited without placing their values in argv. `stop` succeeds only after the
unit is inactive and its cgroup is unpopulated.

When the packet itself is tracked beneath a declared repository `source`, the
runner resolves and reads that packet from the corresponding independent clone
before launch. Its process working directory, default project directory,
control inbox, run-local amendments, steering records, logs, and state therefore
cannot fall back to the author's checkout. The `control` commands use
a prepared workspace id to address that external runtime directly. The explicit
`--workspace MANIFEST` form remains supported. With a default packet binding,
contract and amendment commands can resolve their versioned packet input by id;
otherwise they retain the explicit `--packet PACKET_DIR` requirement.

`watch` writes an append-only JSONL sample stream and a final JSON report under
the operator runtime's `acceptance/` directory. Violations are structured
objects with stable `code` fields such as `runtime_unhealthy`, `not_running`,
and `progress_stale`; a stopped service is therefore durable failure evidence,
not an exception in the monitoring process. A failed sample ends that watch,
and a continuous acceptance interval must start again after the underlying
failure is repaired. With `--json`, every sample and the final report occupy one
line on stdout; an unhealthy report is the last JSON object before exit status
1, with no ANSI or inspected Elixir term appended.

The escript embeds erlexec's compiled native port and materializes it once into
a version-, architecture-, and digest-addressed directory under the current
operator's XDG cache. The cached file is never shared across users, and a
digest mismatch or non-regular path fails startup instead of being overwritten.

## Human Status And Machine Status

The default workspace status is designed for a person checking an unattended
run:

```bash
prompt_runner status operator-packet
```

When the current directory belongs unambiguously to one prepared workspace,
the shorter form is equivalent:

```bash
prompt_runner status
```

Discovery matches the prepared manifest tree, declared source checkout, and
independent clone. Multiple matches fail with the candidate ids instead of
guessing. The report adapts to the workflow: ordinary multi-prompt runs show
prompt progress; an agent-controlled run shows iteration progress only when it
is actually looping; attempts appear for retry/repair; verifier, provider,
activity, service, and process health appear when known.

Automation should request the stable versioned schema explicitly:

```bash
prompt_runner status operator-packet --json
prompt_runner status --workspace workspace.yml --json
```

The JSON response retains the full control snapshot and adds structured
`progress` and `agent_control` summaries. The manifest form remains available
when a caller must not use discovery.

For an agent-controlled run, `agent_control.progress` is the durable
nonterminal cursor reported by the agent itself. It contains the authenticated
run, prompt, and iteration identity plus cursor, optional unit, summary,
timestamp, and `stale`. A retained prior-iteration report is labeled stale and
does not masquerade as current activity. Terminal `last_action` and
`last_reason` remain separate and unchanged.

## Manifest

```yaml
schema: prompt_runner.workspace/v1
id: operator-packet
requires:
  prompt_runner: ">= 0.12.1 and < 0.13.0"
  capabilities:
    - verifier.argv
    - agent_control.linear
    - containment.systemd_user
    - workspace.independent_clone
repositories:
  app:
    remote: git@github.com:owner/app.git
    ref: main
    source: /readable/bootstrap/source/app
packet:
  repo: app
  path: packets/operator-packet
operator:
  workspace_root: auto
  runtime_root: auto
  containment: systemd_user
commits:
  mode: session
  push: explicit
failure_policy: continue_independent
contracts:
  artifacts:
    - id: packet_contracts
      repo: app
      project: support/packet_contracts
      type: escript
```

`packet` is optional. When present, `repo` must name a declared repository and
`path` must be a non-escaping repository-relative directory. Absolute paths,
unknown repositories, `..` escapes, symlink escapes, and missing clone paths
fail closed. The binding is what permits `plan WORKSPACE_ID`,
`verify WORKSPACE_ID`, `start WORKSPACE_ID`, and workspace contract operations
without a packet path. A manifest without it remains valid and uses the
preserved explicit form:

```bash
prompt_runner start --workspace workspace.yml --packet packet --remaining --no-commit
```

`source` is bootstrap input only. The resulting clone's `origin` is `remote`.
At runtime, logical packet repositories bind to the independent clones, prompt
and system text are rebound away from author-machine paths, and verifier argv
may use `@repo:app/path` or an `@artifact:packet_contracts` executable.

## What a workspace deliberately does not do

It does not run `sudo`, change ownership, edit shell profiles, symlink another
user's asdf installation, share `_build` or `deps`, create Git worktrees against
another user's repository, or automate ownership ping-pong. Each operator
installs the runtimes pinned by the repositories and owns every mutable path it
uses.
