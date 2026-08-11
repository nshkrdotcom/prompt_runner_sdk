defmodule PromptRunner.WorkspaceTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Workspace
  alias PromptRunner.Workspace.Manifest

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
    assert runner.config.project_dir != clone
    assert runner.state_dir == state
    assert {PromptRunner.RuntimeStore.FileStore, store} = runner.runtime_store
    assert store.progress_file == Path.join(state, "progress.log")
    refute String.starts_with?(runner.state_dir, packet)
    assert runner.options.path_rewrites[source] == clone
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
