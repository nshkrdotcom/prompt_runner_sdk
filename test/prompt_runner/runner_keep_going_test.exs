defmodule PromptRunner.RunnerKeepGoingTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_keep_going_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    repo = FSHelpers.git_repo!("prompt_runner_keep_going_repo")

    root =
      FSHelpers.packet!(
        "prompt_runner_keep_going_packet",
        """
        ---
        name: "keep-going"
        profile: "simulated-default"
        provider: "simulated"
        model: "simulated-demo"
        recovery:
          repair:
            enabled: false
        repos:
          app:
            path: "#{repo}"
            default: true
        ---
        # Keep Going Packet
        """,
        Enum.map(~w(01 02), fn id ->
          {"#{id}_failure.prompt.md",
           """
           ---
           id: "#{id}"
           phase: 1
           name: "Failure #{id}"
           targets: ["app"]
           verify:
             files_exist:
               - "never-#{id}.txt"
           ---
           # Failure #{id}
           """}
        end)
      )

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
      File.rm_rf!(root)
      File.rm_rf!(repo)
    end)

    {:ok, root: root}
  end

  test "fail-fast remains the default", %{root: root} do
    capture_io(fn ->
      assert {:error, {:verification_failed, _report}} =
               PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    {:ok, state} = PromptRunner.status(root)
    assert get_in(state, ["prompts", "01", "status"]) == "verification_failed"
    assert get_in(state, ["prompts", "02"]) == nil
  end

  test "keep-going attempts every selected prompt and returns every failure", %{root: root} do
    output =
      capture_io(fn ->
        assert {:error, {:prompts_failed, failures}} =
                 PromptRunner.run(root,
                   interface: :cli,
                   no_commit: true,
                   keep_going: true
                 )

        assert Enum.map(failures, & &1.prompt) == ~w(01 02)
      end)

    {:ok, state} = PromptRunner.status(root)
    assert get_in(state, ["prompts", "01", "status"]) == "verification_failed"
    assert get_in(state, ["prompts", "02", "status"]) == "verification_failed"
    assert output =~ "2 selected prompt(s) failed"
  end

  test "keep-going halts on verifier infrastructure faults", %{root: root} do
    prompt = Path.join(root, "prompts/01_failure.prompt.md")

    prompt
    |> File.read!()
    |> String.replace(
      "files_exist:\n    - \"never-01.txt\"",
      "commands:\n    - \"./missing-verifier\""
    )
    |> then(&File.write!(prompt, &1))

    capture_io(fn ->
      assert {:error, {:verifier_fault, _faults}} =
               PromptRunner.run(root,
                 interface: :cli,
                 no_commit: true,
                 keep_going: true
               )
    end)

    {:ok, state} = PromptRunner.status(root)
    assert get_in(state, ["prompts", "01", "status"]) == "verifier_fault"
    assert get_in(state, ["prompts", "02"]) == nil
  end
end
