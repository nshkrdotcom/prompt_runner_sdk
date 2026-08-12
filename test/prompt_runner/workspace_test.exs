defmodule PromptRunner.WorkspaceTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.CLI
  alias PromptRunner.Control.{Plane, Snapshot, Store}
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Workspace
  alias PromptRunner.Workspace.{Manifest, Watch}

  setup do
    root = FSHelpers.tmp_dir("prompt_runner_workspace_test")
    xdg_data = Path.join(root, "data")
    xdg_state = Path.join(root, "state")
    previous_data = System.get_env("XDG_DATA_HOME")
    previous_state = System.get_env("XDG_STATE_HOME")
    System.put_env("XDG_DATA_HOME", xdg_data)
    System.put_env("XDG_STATE_HOME", xdg_state)

    source = FSHelpers.git_repo!("prompt_runner_workspace_source")
    artifact_project = Path.join(source, "contract_tool")
    File.mkdir_p!(Path.join(artifact_project, "lib"))

    File.write!(Path.join(artifact_project, "mix.exs"), """
    defmodule ContractTool.MixProject do
      use Mix.Project

      def project, do: [app: :contract_tool, version: "0.1.0", escript: [main_module: ContractTool]]
    end
    """)

    File.write!(Path.join(artifact_project, "lib/contract_tool.ex"), """
    defmodule ContractTool do
      def main(_args), do: IO.puts("ready")
    end
    """)

    {_output, 0} = System.cmd("git", ["add", "contract_tool"], cd: source, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "add contract tool"],
        cd: source,
        stderr_to_stdout: true
      )

    remote = FSHelpers.bare_repo!("prompt_runner_workspace_remote")
    branch = FSHelpers.push_to_origin!(source, remote)

    packet =
      FSHelpers.packet!(
        "prompt_runner_workspace_packet",
        """
        ---
        name: "workspace-packet"
        profile: "simulated-default"
        provider: "simulated"
        model: "simulated-demo"
        repos:
          app:
            path: "#{source}"
            default: true
        ---
        # Workspace Packet
        """,
        [
          {"01_step.prompt.md",
           """
           ---
           id: "01"
           phase: 1
           name: "Step"
           targets: ["app"]
           verify:
             files_exist: ["README.md"]
           ---
           # Step
           """}
        ]
      )

    manifest = Path.join(root, "workspace.yml")

    File.write!(manifest, """
    schema: prompt_runner.workspace/v1
    id: test-workspace
    requires:
      prompt_runner: ">= 0.10.0 and < 1.0.0"
      capabilities:
        - workspace.independent_clone
        - selector.upper_bound
    repositories:
      app:
        remote: "#{remote}"
        ref: "#{branch}"
        source: "#{source}"
    operator:
      workspace_root: auto
      runtime_root: auto
      containment: systemd_user
    commits:
      mode: session
      push: explicit
    failure_policy: fail_fast
    """)

    on_exit(fn ->
      restore_env("XDG_DATA_HOME", previous_data)
      restore_env("XDG_STATE_HOME", previous_state)
      File.rm_rf!(root)
      File.rm_rf!(source)
      File.rm_rf!(remote)
      File.rm_rf!(packet)
    end)

    {:ok,
     root: root,
     source: source,
     remote: remote,
     packet: packet,
     manifest: manifest,
     xdg_data: xdg_data,
     xdg_state: xdg_state}
  end

  test "strict manifest parsing rejects unknown keys before mutation", %{manifest: manifest} do
    File.write!(manifest, File.read!(manifest) <> "surprise: true\n")

    assert {:error, {:unknown_workspace_keys, [], ["surprise"]}} = Manifest.load(manifest)
  end

  test "prepare creates a full independent clone and an immutable lock record", %{
    manifest: manifest,
    source: source,
    xdg_data: xdg_data
  } do
    assert {:ok, report} = Workspace.prepare(manifest)
    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])

    assert report.repositories["app"].path == clone
    assert File.dir?(Path.join(clone, ".git"))
    refute File.exists?(Path.join([clone, ".git", "objects", "info", "alternates"]))

    assert File.stat!(Path.join(source, "README.md")).inode !=
             File.stat!(Path.join(clone, "README.md")).inode

    assert {:ok, lock} = report.lock_path |> File.read!() |> Jason.decode()
    assert lock["schema"] == "prompt_runner.workspace.lock/v1"

    reference_path =
      Path.join([
        xdg_data,
        "prompt_runner",
        "workspace-references",
        "test-workspace.json"
      ])

    assert {:ok, reference_record} = reference_path |> File.read!() |> Jason.decode()
    assert reference_record["schema"] == "prompt_runner.workspace.reference/v1"
    assert reference_record["workspace"] == "test-workspace"
    assert reference_record["lock"] == report.lock_path
  end

  test "prepared workspaces resolve by id and related current directory", %{
    manifest: manifest,
    source: source
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)
    assert {:ok, resolved} = Workspace.resolve("test-workspace")
    assert resolved == Path.expand(manifest)
    assert {:ok, ^resolved} = Workspace.resolve(nil, cwd: source)
  end

  test "prepared workspace ids remain discoverable with custom operator roots", %{
    manifest: manifest,
    root: root
  } do
    custom_workspace = Path.join(root, "custom-workspace")
    custom_runtime = Path.join(root, "custom-runtime")

    manifest
    |> File.read!()
    |> String.replace("workspace_root: auto", "workspace_root: #{custom_workspace}")
    |> String.replace("runtime_root: auto", "runtime_root: #{custom_runtime}")
    |> then(&File.write!(manifest, &1))

    assert {:ok, _prepared} = Workspace.prepare(manifest)
    assert {:ok, resolved} = Workspace.resolve("test-workspace")
    assert resolved == Path.expand(manifest)
  end

  test "current-directory discovery rejects ambiguous prepared workspace identities", %{
    manifest: manifest,
    source: source,
    root: root
  } do
    other_manifest = Path.join(root, "other-workspace.yml")

    manifest
    |> File.read!()
    |> String.replace("id: test-workspace", "id: other-workspace")
    |> then(&File.write!(other_manifest, &1))

    assert {:ok, _prepared} = Workspace.prepare(manifest)
    assert {:ok, _prepared} = Workspace.prepare(other_manifest)

    assert {:error, {:workspace_discovery_ambiguous, cwd, ids}} =
             Workspace.resolve(nil, cwd: source)

    assert cwd == Path.expand(source)
    assert Enum.sort(ids) == ["other-workspace", "test-workspace"]
  end

  test "status CLI accepts an id or related current directory and defaults to a human report", %{
    manifest: manifest,
    source: source
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)

    output = capture_io(fn -> assert :ok = CLI.main(["status", "test-workspace"]) end)

    assert output =~ "test-workspace — NOT_STARTED"
    assert output =~ "service"
    refute output =~ "\"schema\""

    discovered =
      File.cd!(source, fn ->
        capture_io(fn -> assert :ok = CLI.main(["status"]) end)
      end)

    assert discovered =~ "test-workspace — NOT_STARTED"

    json =
      capture_io(fn -> assert :ok = CLI.main(["status", "test-workspace", "--json"]) end)
      |> Jason.decode!()

    assert json["workspace"] == "test-workspace"
    assert json["schema"] == "prompt_runner.workspace.status/v1"
  end

  test "prepare falls back to the canonical remote when bootstrap source is unusable", %{
    manifest: manifest,
    remote: remote,
    root: root,
    xdg_data: xdg_data
  } do
    unusable_source = Path.join(root, "missing-bootstrap-source")
    manifest_contents = File.read!(manifest)

    File.write!(
      manifest,
      String.replace(manifest_contents, ~r/source: .+/, "source: #{unusable_source}")
    )

    assert {:ok, report} = Workspace.prepare(manifest)
    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])

    assert report.repositories["app"].path == clone
    assert File.dir?(Path.join(clone, ".git"))
    assert PromptRunner.Git.value(clone, ["remote", "get-url", "origin"]) == remote
  end

  test "workspace plan overlays logical repos and relocates all runner state", %{
    manifest: manifest,
    packet: packet,
    source: source,
    xdg_data: xdg_data,
    xdg_state: xdg_state
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)
    assert {:ok, %{runner: runner}} = Workspace.plan(manifest, packet)

    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])
    state = Path.join([xdg_state, "prompt_runner", "workspaces", "test-workspace", "packet"])

    assert [%{name: "app", path: ^clone}] = runner.config.target_repos
    assert runner.config.project_dir == clone
    assert runner.state_dir == state
    assert {PromptRunner.RuntimeStore.FileStore, store} = runner.runtime_store
    assert store.progress_file == Path.join(state, "progress.log")
    refute String.starts_with?(runner.state_dir, packet)
    assert runner.options.path_rewrites[source] == clone
  end

  test "a packet tracked by a workspace repository is read from the independent clone", %{
    manifest: manifest,
    remote: remote,
    root: root,
    source: source,
    xdg_data: xdg_data
  } do
    packet = Path.join(source, "packets/demo")
    File.mkdir_p!(Path.join(packet, "prompts"))

    File.write!(Path.join(packet, "prompt_runner_packet.md"), """
    ---
    name: "workspace-owned-packet"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "#{source}"
        default: true
    ---
    # Workspace-owned packet
    """)

    File.write!(Path.join([packet, "prompts", "01_step.prompt.md"]), """
    ---
    id: "01"
    phase: 1
    name: "Step"
    targets: ["app"]
    ---
    # Step
    """)

    {_output, 0} = System.cmd("git", ["add", "packets/demo"], cd: source, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "add packet"], cd: source, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["push", "origin", "HEAD"], cd: source, stderr_to_stdout: true)

    unrelated = Path.join(root, "an-unrelated-source-with-a-longer-name-than-the-owner")
    File.mkdir_p!(unrelated)
    branch = PromptRunner.Git.value(source, ["branch", "--show-current"])

    File.write!(
      manifest,
      String.replace(
        File.read!(manifest),
        "repositories:\n",
        """
        repositories:
          unrelated:
            remote: "#{remote}"
            ref: "#{branch}"
            source: "#{unrelated}"
        """
      )
    )

    assert {:ok, _prepared} = Workspace.prepare(manifest)
    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])
    expected = Path.join(clone, "packets/demo")

    assert {:ok, ^expected} = Workspace.packet_root(manifest, packet)
    assert {:ok, %{packet_root: ^expected, runner: runner}} = Workspace.plan(manifest, packet)
    assert runner.source_root == expected
    assert runner.config.project_dir == clone
  end

  test "control commands address workspace-external state through the manifest", %{
    manifest: manifest,
    packet: packet,
    xdg_state: xdg_state
  } do
    state = Path.join([xdg_state, "prompt_runner", "workspaces", "test-workspace", "packet"])

    plane =
      Plane.open(packet,
        packet: "workspace-packet",
        state_root: state,
        max_steers: 1
      )

    plane =
      Plane.prompt_started(plane, %{num: "01", name: "Step"}, :run, 1, %{
        sdk: :simulated,
        model: "simulated-demo"
      })

    plane = Plane.record(plane, "test", %{}, outcome: :applied)

    status =
      capture_io(fn ->
        assert :ok = CLI.main(["control", "status", "--workspace", manifest, "--json"])
      end)

    assert Jason.decode!(status)["run_id"] == Plane.run_id(plane)

    log =
      capture_io(fn ->
        assert :ok = CLI.main(["control", "log", "--workspace", manifest, "--json"])
      end)

    assert %{"command" => "test", "outcome" => "applied"} = Jason.decode!(log)

    steer =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "control",
                   "steer",
                   "--workspace",
                   manifest,
                   "inspect",
                   "the",
                   "workspace"
                 ])
      end)

    assert steer =~ "Steer queued"
    {plane, [{:steer, "inspect the workspace", author}]} = Plane.boundary(plane)
    assert is_binary(author)

    Plane.steer_delivered(plane, "inspect the workspace", author, :simulated, :delivered)

    assert File.regular?(Path.join([state, "interventions", "01.jsonl"]))
    refute File.exists?(Path.join([packet, ".prompt_runner", "interventions"]))

    amend =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "control",
                   "amend",
                   "--workspace",
                   manifest,
                   "--packet",
                   packet,
                   "01",
                   "--add-file",
                   "SECOND.md",
                   "--reason",
                   "exercise external state"
                 ])
      end)

    assert amend =~ "Amended 01"
    assert File.regular?(Path.join([state, "amendments", "01.jsonl"]))
    refute File.exists?(Path.join([packet, ".prompt_runner", "amendments"]))

    contract =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "control",
                   "contract",
                   "--workspace",
                   manifest,
                   "--packet",
                   packet,
                   "01",
                   "--json"
                 ])
      end)

    assert "SECOND.md" in Jason.decode!(contract)["enforced"]["files_exist"]
  end

  test "doctor reports dirty state as resumable work rather than blocking restart", %{
    manifest: manifest,
    xdg_data: xdg_data
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)
    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])
    File.write!(Path.join(clone, "DIRTY.txt"), "dirty\n")

    assert {:ok, report} = Workspace.doctor(manifest)
    assert report.ready?
    assert report.repositories["app"].ready?

    assert [[:dirty_resumable_workspace, paths]] = report.repositories["app"].warnings
    assert paths =~ "DIRTY.txt"
    assert is_binary(Jason.encode!(report))
  end

  test "status remains JSON-serializable when the systemd user bus is unavailable", %{
    manifest: manifest
  } do
    command_runner = fn "systemctl", _argv, _opts ->
      {"Failed to connect to bus: No medium found", 1}
    end

    assert {:ok, status} = Workspace.status(manifest, command_runner: command_runner)
    assert status.containment.state == :unknown

    assert status.containment.error == %{
             kind: "systemctl_status_failed",
             exit_code: 1,
             details: "Failed to connect to bus: No medium found"
           }

    assert is_binary(Jason.encode!(status))
  end

  test "status combines selected prompt progress with conditional agent iteration data", %{
    manifest: manifest,
    packet: packet,
    xdg_state: xdg_state
  } do
    packet_manifest = Path.join(packet, "prompt_runner_packet.md")

    File.write!(
      packet_manifest,
      String.replace(
        File.read!(packet_manifest),
        "repos:",
        """
        agent_control:
          enabled: true
          default_action: repeat
          max_iterations: 7
          completion_verify:
            files_exist: [README.md]
        repos:
        """
      )
    )

    state_dir =
      Path.join([xdg_state, "prompt_runner", "workspaces", "test-workspace", "packet"])

    File.mkdir_p!(Path.join(state_dir, "runs"))

    File.write!(
      Path.join([state_dir, "runs", "current.json"]),
      Jason.encode!(%{
        "run_id" => "run-1",
        "state" => "running",
        "selection" => %{"targets" => ["01"]},
        "updated_at" => "2026-08-12T04:00:00Z"
      })
    )

    File.write!(
      Path.join(state_dir, "state.json"),
      Jason.encode!(%{
        "prompts" => %{
          "01" => %{
            "status" => "running",
            "iteration" => 1,
            "agent_control" => %{
              "action" => "repeat",
              "iteration" => 1,
              "reason" => "more work remains"
            },
            "last_verifier" => %{"pass?" => true}
          }
        }
      })
    )

    control_root = Store.state_root(state_dir)
    assert :ok = Store.init(control_root)

    assert :ok =
             Store.write_snapshot(control_root, %Snapshot{
               run_id: "run-1",
               packet_dir: packet,
               packet: "workspace-packet",
               status: :running,
               prompt_id: "01",
               prompt_name: "Step",
               attempt: 1,
               mode: :run,
               provider: :simulated,
               model: "simulated-demo"
             })

    command_runner = fn "systemctl", _argv, _opts -> {"no user bus", 1} end
    assert {:ok, status} = Workspace.status(manifest, command_runner: command_runner)

    assert status.progress == %{
             selected: 1,
             completed: 0,
             running: 1,
             failed: 0,
             blocked: 0,
             pending: 0,
             current_position: 1,
             last_verifier: "passed",
             reason: nil,
             error: nil
           }

    assert status.agent_control == %{
             enabled: true,
             looping: true,
             current_iteration: 2,
             completed_iterations: 1,
             max_iterations: 7,
             last_action: "repeat",
             last_reason: "more work remains"
           }
  end

  test "watch persists a structured failure report when running state is required", %{
    manifest: manifest
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)

    assert {:error, {:workspace_watch_unhealthy, report}} =
             Watch.run(manifest,
               duration_seconds: 1,
               interval_seconds: 1,
               require_running: true,
               require_progress: false,
               json: false
             )

    assert %{state: state} =
             Enum.find(report.violations, fn violation -> violation.code == "not_running" end)

    assert state in ["not_started", "stopped", "failed"]
    assert %{code: "runtime_unhealthy"} in report.violations
    assert File.regular?(report.evidence_jsonl)
    assert File.regular?(report.report_path)

    [sample_json] =
      report.evidence_jsonl
      |> File.read!()
      |> String.split("\n", trim: true)

    assert %{"healthy?" => false, "violations" => violations} = Jason.decode!(sample_json)

    assert %{"code" => "not_running", "state" => state} in violations
    assert %{"code" => "runtime_unhealthy"} in violations

    assert %{"passed?" => false} =
             report.report_path
             |> File.read!()
             |> Jason.decode!()
  end

  test "prepare builds declared contract escripts once and doctor verifies the installed artifact",
       %{
         manifest: manifest,
         xdg_data: xdg_data
       } do
    File.write!(
      manifest,
      File.read!(manifest) <>
        """
        contracts:
          artifacts:
            - id: contract_tool
              repo: app
              project: contract_tool
              type: escript
        """
    )

    assert {:ok, report} = Workspace.prepare(manifest)

    artifact =
      Path.join([
        xdg_data,
        "prompt_runner",
        "workspaces",
        "test-workspace",
        "artifacts",
        "contract_tool"
      ])

    assert report.artifacts["contract_tool"].path == artifact
    assert File.regular?(artifact)
    assert {_output, 0} = System.cmd(artifact, [])
    assert {:ok, %{ready?: true, artifacts: %{ready?: true}}} = Workspace.doctor(manifest)
  end

  test "doctor probes pinned tools from the exact repository cwd without running Mix", %{
    manifest: manifest,
    xdg_data: xdg_data
  } do
    assert {:ok, _prepared} = Workspace.prepare(manifest)
    clone = Path.join([xdg_data, "prompt_runner", "workspaces", "test-workspace", "repos", "app"])
    File.write!(Path.join(clone, ".tool-versions"), "erlang 999.0-impossible\n")
    {_output, 0} = System.cmd("git", ["add", ".tool-versions"], cd: clone, stderr_to_stdout: true)

    {_output, 0} =
      System.cmd("git", ["commit", "-m", "test pin"], cd: clone, stderr_to_stdout: true)

    assert {:ok, report} = Workspace.doctor(manifest)
    refute report.ready?
    refute report.toolchains.ready?

    assert [%{tool: "erlang", required: "999.0-impossible", ready?: false}] =
             Enum.map(report.toolchains.projects, &Map.take(&1, [:tool, :required, :ready?]))
  end

  test "legacy state import carries only completed prompts and writes a receipt", %{
    manifest: manifest,
    packet: packet,
    xdg_state: xdg_state
  } do
    legacy_dir = Path.join(packet, ".prompt_runner")
    File.mkdir_p!(legacy_dir)

    File.write!(Path.join(legacy_dir, "progress.log"), """
    01:failed:2026-08-10T01:00:00Z
    01:completed:2026-08-10T02:00:00Z:abc1234
    """)

    assert {:ok, report} = Workspace.import_state(manifest, packet)
    assert report.imported_completed == ["01"]
    assert File.read!(report.progress_file) == "01:completed:2026-08-10T02:00:00Z:no_session\n"

    assert {:ok, receipt} = report.receipt |> File.read!() |> Jason.decode()
    assert receipt["schema"] == "prompt_runner.state_import/v1"
    assert receipt["policy"] == "latest_completed_only"

    assert receipt["completed"] == [
             %{
               "id" => "01",
               "source_commit" => "abc1234",
               "source_timestamp" => "2026-08-10T02:00:00Z"
             }
           ]

    expected_progress =
      Path.join([
        xdg_state,
        "prompt_runner",
        "workspaces",
        "test-workspace",
        "packet",
        "progress.log"
      ])

    assert report.progress_file == expected_progress

    assert {:error, {:workspace_progress_already_exists, ^expected_progress}} =
             Workspace.import_state(manifest, packet)
  end

  test "legacy state import rejects records for another packet", %{
    manifest: manifest,
    packet: packet
  } do
    legacy_dir = Path.join(packet, ".prompt_runner")
    File.mkdir_p!(legacy_dir)
    File.write!(Path.join(legacy_dir, "progress.log"), "99:completed:2026-08-10T02:00:00Z\n")

    assert {:error, {:legacy_progress_unknown_prompts, ["99"]}} =
             Workspace.import_state(manifest, packet)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
