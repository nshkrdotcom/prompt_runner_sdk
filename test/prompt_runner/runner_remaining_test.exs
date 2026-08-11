defmodule PromptRunner.RunnerRemainingTest do
  @moduledoc """
  What a resume actually runs.

  `--continue` resumes from `last_completed + 1`, so a packet whose 03 failed
  while 04 succeeded resumes at 05 and steps over 03 without saying so. Both
  live packets worked around it by carrying a `remaining_prompts()` bash
  function that read the progress store directly — the same behaviour,
  implemented twice, in shell.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.Profile
  alias PromptRunner.Progress
  alias PromptRunner.Runner
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_remaining_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    root = FSHelpers.tmp_dir("prompt_runner_remaining_root")
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(Path.join(root, "prompts"))
    File.mkdir_p!(workspace)
    {_out, 0} = System.cmd("git", ["init", "--quiet", workspace], stderr_to_stdout: true)

    File.write!(Path.join(root, "prompt_runner_packet.md"), """
    ---
    name: "remaining"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "./workspace"
        default: true
    ---
    # Remaining packet
    """)

    for id <- ~w(01 02 03 04) do
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

  defp progress_file(root), do: Path.join([root, ".prompt_runner", "progress.log"])

  defp write_progress!(root, lines) do
    path = progress_file(root)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Enum.map_join(lines, "\n", & &1) <> "\n")
  end

  defp plan!(root) do
    {:ok, plan} = PromptRunner.plan(root, interface: :cli)
    plan
  end

  describe "Progress.remaining/2" do
    test "a completed prompt is not remaining", %{root: root} do
      write_progress!(root, ["01:completed:2026-08-10T00:00:00Z:abc1234"])

      assert Progress.remaining(plan!(root), ~w(01 02 03 04)) == ~w(02 03 04)
    end

    test "a failed prompt is remaining", %{root: root} do
      write_progress!(root, [
        "01:completed:2026-08-10T00:00:00Z:abc1234",
        "02:failed:2026-08-10T00:01:00Z"
      ])

      assert Progress.remaining(plan!(root), ~w(01 02 03 04)) == ~w(02 03 04)
    end

    test "a prompt with no record is remaining", %{root: root} do
      write_progress!(root, ["04:completed:2026-08-10T00:00:00Z:abc1234"])

      assert Progress.remaining(plan!(root), ~w(01 02 03 04)) == ~w(01 02 03)
    end

    test "a prompt completed and then failed takes its latest status", %{root: root} do
      write_progress!(root, [
        "02:completed:2026-08-10T00:00:00Z:abc1234",
        "02:failed:2026-08-10T00:05:00Z"
      ])

      assert "02" in Progress.remaining(plan!(root), ~w(01 02 03 04))
    end

    test "an unreadable store makes every prompt remaining", %{root: root} do
      refute File.exists?(progress_file(root))

      assert Progress.remaining(plan!(root), ~w(01 02 03 04)) == ~w(01 02 03 04)
    end

    test "the requested order is preserved", %{root: root} do
      write_progress!(root, ["02:completed:2026-08-10T00:00:00Z:abc1234"])

      assert Progress.remaining(plan!(root), ~w(04 03 02 01)) == ~w(04 03 01)
    end
  end

  describe "--remaining target selection" do
    test "runs exactly the unfinished prompts, including ones before the last completed", %{
      root: root
    } do
      write_progress!(root, [
        "01:completed:2026-08-10T00:00:00Z:abc1234",
        "02:failed:2026-08-10T00:01:00Z",
        "04:completed:2026-08-10T00:02:00Z:def5678"
      ])

      assert {:ok, ~w(02 03)} =
               Runner.build_targets_for_test(plan!(root), [run: true, remaining: true], [])
    end

    test "an all-completed packet selects nothing rather than everything", %{root: root} do
      write_progress!(
        root,
        Enum.map(~w(01 02 03 04), &"#{&1}:completed:2026-08-10T00:00:00Z:abc1234")
      )

      assert {:ok, []} =
               Runner.build_targets_for_test(plan!(root), [run: true, remaining: true], [])
    end

    test "explicit ids still win over --remaining", %{root: root} do
      write_progress!(root, ["01:completed:2026-08-10T00:00:00Z:abc1234"])

      assert {:ok, ~w(01)} =
               Runner.build_targets_for_test(plan!(root), [run: true, remaining: true], ~w(01))
    end
  end

  describe "--continue" do
    test "still resumes after the last completed prompt", %{root: root} do
      write_progress!(root, [
        "01:completed:2026-08-10T00:00:00Z:abc1234",
        "02:failed:2026-08-10T00:01:00Z",
        "03:completed:2026-08-10T00:02:00Z:def5678"
      ])

      assert {:ok, ~w(04)} =
               capture_targets(plan!(root), continue: true)
    end

    test "names the prompts it is stepping over and points at --remaining", %{root: root} do
      write_progress!(root, [
        "01:completed:2026-08-10T00:00:00Z:abc1234",
        "02:failed:2026-08-10T00:01:00Z",
        "03:completed:2026-08-10T00:02:00Z:def5678"
      ])

      output =
        capture_io(fn ->
          Runner.build_targets_for_test(plan!(root), [run: true, continue: true], [])
        end)

      assert output =~ "02"
      assert output =~ "--remaining"
    end

    test "says nothing when it skips nothing", %{root: root} do
      write_progress!(root, ["01:completed:2026-08-10T00:00:00Z:abc1234"])

      output =
        capture_io(fn ->
          Runner.build_targets_for_test(plan!(root), [run: true, continue: true], [])
        end)

      refute output =~ "--remaining"
    end
  end

  # `PromptRunner.run/2` is the only entry point an embedded caller has. Until
  # it read `:prompts`, running a named subset needed `Runner.execute_plan/3` —
  # a function on a module carrying `@moduledoc false`.
  describe "selection through the public API" do
    test "prompts: selects exactly those ids", %{root: root} do
      assert {:ok, ~w(03 01)} =
               Runner.build_targets_for_test(plan!(root), [run: true], ~w(03 01))

      assert capture_run_targets(root, prompts: ["03", "01"]) == ~w(03 01)
    end

    test "prompts: accepts integers and unpadded ids", %{root: root} do
      assert capture_run_targets(root, prompts: [3, "1"]) == ~w(03 01)
    end

    test "prompts: does not silently fall back to running everything", %{root: root} do
      assert capture_run_targets(root, prompts: ["02"]) == ~w(02)
    end

    test "remaining: true is honoured through the public API", %{root: root} do
      write_progress!(root, ["01:completed:2026-08-10T00:00:00Z:abc1234"])

      assert capture_run_targets(root, remaining: true) == ~w(02 03 04)
    end

    test "no selector still runs everything", %{root: root} do
      assert capture_run_targets(root, []) == ~w(01 02 03 04)
    end
  end

  # `--dry-run` takes the same `build_targets/3` path a real run does and
  # announces each selected prompt, so it reports the selection without
  # starting a provider.
  defp capture_run_targets(root, opts) do
    output =
      capture_io(fn ->
        PromptRunner.run(root, [interface: :cli, dry_run: true, no_commit: true] ++ opts)
      end)

    ~r/\[DRY RUN\] Prompt (\d+):/
    |> Regex.scan(output, capture: :all_but_first)
    |> List.flatten()
  end

  defp capture_targets(plan, opts) do
    capture_io(fn ->
      send(self(), {:targets, Runner.build_targets_for_test(plan, [run: true] ++ opts, [])})
    end)

    assert_receive {:targets, result}
    result
  end
end
