defmodule PromptRunner.RunnerTargetSelectionTest do
  @moduledoc """
  Which prompts a run actually executes.

  Regression coverage for a silent-truncation defect: `build_targets/3` returned
  `[hd(remaining)]`, so `run PACKET 01 02 03` executed only `01`, exited 0, and
  reported success. The multi-prompt form has been documented in `guides/cli.md`
  since the CLI existed.

  It bit an unattended program during a mid-run resume: relaunching with the
  nineteen remaining prompt ids ran exactly one and stopped, with a clean exit
  code and nothing in the log to say the other eighteen had been dropped.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_targets_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    root = FSHelpers.tmp_dir("prompt_runner_targets_root")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(root, "prompts"))
    File.mkdir_p!(workspace)
    {_out, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)

    File.write!(Path.join(root, "prompt_runner_packet.md"), """
    ---
    name: "targets"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "./workspace"
        default: true
    ---
    # Targets packet
    """)

    for id <- ~w(01 02 03) do
      File.write!(Path.join([root, "prompts", "#{id}_step.prompt.md"]), """
      ---
      id: "#{id}"
      phase: 1
      name: "Step #{id}"
      targets:
        - "app"
      verify:
        files_exist:
          - "never.txt"
      ---
      # Step #{id}
      """)
    end

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  defp targets(root, ids) do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)
    PromptRunner.Runner.build_targets_for_test(plan, [run: true], ids)
  end

  test "every listed prompt is a target, in the order given", %{root: root} do
    assert {:ok, ["01", "02", "03"]} = targets(root, ~w(01 02 03))
  end

  test "a two-prompt list does not collapse to one", %{root: root} do
    assert {:ok, ["02", "03"]} = targets(root, ~w(02 03))
  end

  test "order is preserved rather than sorted", %{root: root} do
    assert {:ok, ["03", "01"]} = targets(root, ~w(03 01))
  end

  test "a single prompt still works", %{root: root} do
    assert {:ok, ["02"]} = targets(root, ~w(02))
  end

  test "an unknown id is an error, not a silent no-op", %{root: root} do
    assert {:error, {:unknown_prompts, ["99"], known}} = targets(root, ~w(01 99))
    assert "01" in known
  end

  test "--all still selects everything when no ids are given", %{root: root} do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    assert {:ok, ["01", "02", "03"]} =
             PromptRunner.Runner.build_targets_for_test(plan, [run: true, all: true], [])
  end

  test "--through is an exact upper bound", %{root: root} do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    assert {:ok, ["01", "02"]} =
             PromptRunner.Runner.build_targets_for_test(
               plan,
               [run: true, all: true, through: "02"],
               []
             )
  end

  test "bounds select the packet range without requiring a redundant --all", %{root: root} do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    assert {:ok, ["02", "03"]} =
             PromptRunner.Runner.build_targets_for_test(
               plan,
               [run: true, from: "02", through: "03"],
               []
             )
  end

  test "--from and --through form an inclusive range", %{root: root} do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    assert {:ok, ["02"]} =
             PromptRunner.Runner.build_targets_for_test(
               plan,
               [run: true, all: true, from: "02", through: "02"],
               []
             )
  end

  test "an unknown range endpoint fails instead of shortening the run", %{root: root} do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)

    assert {:error, {:unknown_prompt_bound, :through, "99", known}} =
             PromptRunner.Runner.build_targets_for_test(
               plan,
               [run: true, all: true, through: "99"],
               []
             )

    assert "03" in known
  end

  test "no ids and no selector is an error rather than a silent empty run", %{root: root} do
    assert {:error, :no_target} = targets(root, [])
  end
end
