# Operator Workspaces

Prompt Runner 0.11.0 replaces packet-specific shell orchestration with a strict
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
prompt_runner verify --workspace workspace.yml --packet packet 01
prompt_runner start --workspace workspace.yml --packet packet --remaining --no-commit
prompt_runner status --workspace workspace.yml
prompt_runner watch --workspace workspace.yml --for 240m --every 10m \
  --require-running --require-progress --progress-timeout 60m
prompt_runner stop --workspace workspace.yml
```

`prepare` is the only materializing operation. It clones without hardlinks or
Git alternates, refuses dirty existing clones, fast-forwards only, and builds
declared contract escripts into the operator's workspace. `doctor` is read-only:
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

## Manifest

```yaml
schema: prompt_runner.workspace/v1
id: operator-packet
requires:
  prompt_runner: ">= 0.11.0 and < 0.12.0"
  capabilities:
    - verifier.argv
    - containment.systemd_user
    - workspace.independent_clone
repositories:
  app:
    remote: git@github.com:owner/app.git
    ref: main
    source: /readable/bootstrap/source/app
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
