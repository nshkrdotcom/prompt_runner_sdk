defmodule PromptRunner.VerifierFaultTest do
  @moduledoc """
  Telling a broken verifier apart from failed work.

  `pass?: code == 0` cannot distinguish "the check ran and the work failed"
  from "the check could not run". On 2026-08-10 a contract kept referencing
  `docs/20260809/bin/check_doc.sh` after those scripts moved one directory
  down. Every clause exited 127, the runner read that as failed work, and a
  finished attempt was discarded on evidence that never existed.
  """

  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers
  alias PromptRunner.Verifier

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_fault_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  defp packet_with_command!(command) do
    packet_root = FSHelpers.tmp_dir("prompt_runner_fault_packet")
    repo = FSHelpers.git_repo!("prompt_runner_fault_repo")

    on_exit(fn ->
      File.rm_rf!(packet_root)
      File.rm_rf!(repo)
    end)

    File.mkdir_p!(Path.join(packet_root, "prompts"))

    File.write!(Path.join(packet_root, "prompt_runner_packet.md"), """
    ---
    name: "fault-packet"
    profile: "simulated-default"
    provider: "simulated"
    model: "simulated-demo"
    repos:
      app:
        path: "#{repo}"
        default: true
    ---
    # Fault packet
    """)

    File.write!(Path.join(packet_root, "prompts/01_check.prompt.md"), """
    ---
    id: "01"
    phase: 1
    name: "Check"
    targets:
      - "app"
    verify:
      commands:
        - "#{command}"
    ---
    # Check
    """)

    {:ok, plan} = PromptRunner.plan(packet_root, interface: :cli)
    {plan, hd(plan.prompts), repo}
  end

  defp report_for(command) do
    {plan, prompt, repo} = packet_with_command!(command)
    {Verifier.verify_prompt(plan, prompt), repo}
  end

  test "a command that does not exist is a fault, not a verification failure" do
    {report, _repo} = report_for("./definitely_not_here.sh")

    refute report.pass?
    assert [item] = report.faults
    assert item.fault == :verifier_fault
    assert item.exit_code == 127
    assert item.details =~ "command not found"
  end

  test "a command that exists and is not executable is a fault" do
    {plan, prompt, repo} = packet_with_command!("./not_executable.sh")
    File.write!(Path.join(repo, "not_executable.sh"), "#!/bin/sh\nexit 0\n")
    File.chmod!(Path.join(repo, "not_executable.sh"), 0o644)

    report = Verifier.verify_prompt(plan, prompt)

    assert [item] = report.faults
    assert item.fault == :verifier_fault
    assert item.exit_code == 126
  end

  test "a command killed by timeout is a timeout fault, not a failed check" do
    {report, _repo} = report_for("timeout 1 sleep 5")

    assert [item] = report.faults
    assert item.fault == :verifier_timeout
    assert item.exit_code == 124
  end

  test "a check that ran and disagreed is a failure, with no fault" do
    {report, _repo} = report_for("exit 1")

    refute report.pass?
    assert report.faults == []
    assert [item] = report.failures
    assert item.exit_code == 1
    assert item.fault == nil
  end

  test "a check that ran and passed is neither" do
    {report, _repo} = report_for("exit 0")

    assert report.pass?
    assert report.faults == []
    assert report.failures == []
  end

  test "verification commands inherit the runner environment without a login shell" do
    {report, _repo} =
      report_for("if shopt -q login_shell; then echo unexpected-login-shell; exit 9; fi")

    assert report.pass?
  end

  test "fault_line names the command and the directory it could not run in" do
    {report, repo} = report_for("./definitely_not_here.sh")

    line = report.faults |> hd() |> Verifier.fault_line()

    assert line =~ "definitely_not_here.sh"
    assert line =~ repo
    assert line =~ "127"
  end

  test "fault?/1 and faults/1 read a report round-tripped through JSON state" do
    {report, _repo} = report_for("./definitely_not_here.sh")

    decoded = report |> Jason.encode!() |> Jason.decode!()

    assert Verifier.fault?(decoded)
    assert [item] = Verifier.faults(decoded)
    assert item["exit_code"] == 127
  end

  test "faults/1 recovers faults from a report that predates the faults key" do
    {report, _repo} = report_for("./definitely_not_here.sh")

    assert Verifier.fault?(Map.delete(report, :faults))
  end
end
