defmodule PromptRunner.AgentControlRunnerTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import Mox

  alias PromptRunner.AgentControl
  alias PromptRunner.Profile
  alias PromptRunner.Progress
  alias PromptRunner.Test.FSHelpers

  setup :verify_on_exit!

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_agent_control_home")
    previous_config_home = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    previous_llm = Application.get_env(:prompt_runner, :llm_module)
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()
    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)

    repo = FSHelpers.git_repo!("prompt_runner_agent_control_repo")
    root = packet(repo)

    on_exit(fn ->
      if previous_config_home,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous_config_home),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      if previous_llm,
        do: Application.put_env(:prompt_runner, :llm_module, previous_llm),
        else: Application.delete_env(:prompt_runner, :llm_module)

      File.rm_rf!(config_home)
      File.rm_rf!(root)
      File.rm_rf!(repo)
    end)

    {:ok, root: root, repo: repo}
  end

  test "repeat re-runs the current prompt before continuing the linear sequence", %{
    root: root
  } do
    calls = Agent.start_link(fn -> [] end) |> elem(1)

    expect(PromptRunner.LLMMock, :start_stream, 3, fn llm, prompt ->
      Agent.update(calls, &(&1 ++ [{llm.prompt_id, prompt}]))

      if llm.prompt_id == "01" and count(calls, "01") == 1 do
        assert {:ok, _receipt} =
                 AgentControl.request("repeat",
                   env: control_env(llm),
                   reason: "one more pass"
                 )
      end

      successful_stream(llm)
    end)

    capture_io(fn ->
      assert {:ok, _run} = PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    assert Enum.map(Agent.get(calls, & &1), &elem(&1, 0)) == ~w(01 01 02)

    {:ok, plan} = PromptRunner.plan(root, interface: :cli)
    statuses = Progress.statuses(plan)
    assert statuses["01"].status == "completed"
    assert statuses["02"].status == "completed"
  end

  test "finish closes the selected sequence only after completion verification passes", %{
    root: root,
    repo: repo
  } do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      File.write!(Path.join(repo, "P09R_COMPLETE"), "complete\n")

      assert {:ok, _receipt} =
               AgentControl.request("finish",
                 env: control_env(llm),
                 reason: "all packet work is complete"
               )

      successful_stream(llm)
    end)

    capture_io(fn ->
      assert {:ok, _run} = PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    {:ok, state} = PromptRunner.status(root)
    assert get_in(state, ["prompts", "01", "agent_control", "action"]) == "finish"
    assert get_in(state, ["prompts", "02"]) == nil

    # The global completion contract prevents a later --remaining invocation
    # from opening another provider session for the unvisited second prompt.
    capture_io(fn ->
      assert {:ok, _run} =
               PromptRunner.run(root, interface: :cli, remaining: true, no_commit: true)
    end)
  end

  test "a rejected finish starts a fresh iteration with the verifier failures", %{
    root: root,
    repo: repo
  } do
    calls = Agent.start_link(fn -> 0 end) |> elem(1)

    expect(PromptRunner.LLMMock, :start_stream, 2, fn llm, prompt ->
      call = Agent.get_and_update(calls, &{&1 + 1, &1 + 1})

      if call == 1 do
        assert {:ok, _receipt} =
                 AgentControl.request("finish",
                   env: control_env(llm),
                   reason: "I think it is complete"
                 )
      else
        assert prompt =~ "previous `finish` request was rejected"
        assert prompt =~ "P09R_COMPLETE"
        File.write!(Path.join(repo, "P09R_COMPLETE"), "complete\n")

        assert {:ok, _receipt} =
                 AgentControl.request("finish",
                   env: control_env(llm),
                   reason: "completion verification is now green"
                 )
      end

      successful_stream(llm)
    end)

    capture_io(fn ->
      assert {:ok, _run} = PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    assert Agent.get(calls, & &1) == 2
  end

  test "the iteration limit fails resumably instead of looping forever", %{root: root} do
    set_max_iterations(root, 2)
    set_default_action(root, "repeat")

    expect(PromptRunner.LLMMock, :start_stream, 2, fn llm, _prompt -> successful_stream(llm) end)

    capture_io(fn ->
      assert {:error, {:agent_control_iteration_limit, "01", 2}} =
               PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    {:ok, plan} = PromptRunner.plan(root, interface: :cli)
    assert Progress.statuses(plan)["01"].status == "failed"
  end

  test "blocked stops the sequence as incomplete with the agent's reason", %{root: root} do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt ->
      assert {:ok, _receipt} =
               AgentControl.request("blocked",
                 env: control_env(llm),
                 reason: "the required remote repository does not exist"
               )

      successful_stream(llm)
    end)

    capture_io(fn ->
      assert {:error,
              {:agent_control_blocked, "01", "the required remote repository does not exist"}} =
               PromptRunner.run(root, interface: :cli, no_commit: true)
    end)

    {:ok, state} = PromptRunner.status(root)
    assert get_in(state, ["prompts", "01", "status"]) == "agent_control_blocked"
    assert get_in(state, ["prompts", "02"]) == nil
  end

  test "a provider launch failure cannot become a successful controlled iteration", %{
    root: root
  } do
    expect(PromptRunner.LLMMock, :start_stream, fn llm, _prompt -> failed_stream(llm) end)

    capture_io(fn ->
      assert {:error, reason} = PromptRunner.run(root, interface: :cli, no_commit: true)
      assert inspect(reason) =~ "invalid provider CLI arguments"
    end)

    {:ok, plan} = PromptRunner.plan(root, interface: :cli)
    assert Progress.statuses(plan)["01"].status == "failed"

    {:ok, state} = PromptRunner.status(root)
    assert Enum.map(state["prompts"]["01"]["attempts"], & &1["status"]) == ["failed"]
  end

  defp packet(repo) do
    FSHelpers.packet!(
      "prompt_runner_agent_control_packet",
      """
      ---
      name: "agent-control"
      profile: "simulated-default"
      provider: "simulated"
      model: "simulated-demo"
      recovery:
        repair:
          enabled: false
      agent_control:
        enabled: true
        default_action: "continue"
        max_iterations: 4
        completion_verify:
          files_exist:
            - repo: "app"
              path: "P09R_COMPLETE"
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Agent control packet
      """,
      Enum.map(~w(01 02), fn id ->
        {"#{id}_step.prompt.md",
         """
         ---
         id: "#{id}"
         phase: 1
         name: "Step #{id}"
         targets: ["app"]
         verify:
           commands:
             - exec: "test"
               args: ["-f", "README.md"]
               timeout_ms: 60000
         ---
         # Step #{id}

         Do the work for step #{id}.
         """}
      end)
    )
  end

  defp successful_stream(llm) do
    stream = [
      %{type: :run_started, data: %{model: llm.model}},
      %{type: :message_streamed, data: %{delta: "ok"}},
      %{type: :run_completed, data: %{stop_reason: "end_turn"}}
    ]

    {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
  end

  defp failed_stream(llm) do
    stream = [
      %{type: :run_started, data: %{model: llm.model}},
      %{
        type: :run_failed,
        data: %{
          error_message: "invalid provider CLI arguments",
          provider_error: %{
            provider: :claude,
            kind: :config_invalid,
            message: "invalid provider CLI arguments",
            recovery: %{
              class: :provider_config_claim,
              retryable?: false,
              repairable?: false,
              resumeable?: false,
              local_deterministic?: true,
              remote_claim?: false
            }
          }
        }
      }
    ]

    {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
  end

  defp control_env(llm) do
    llm.adapter_opts
    |> Map.get(:env, %{})
  end

  defp count(agent, prompt_id) do
    agent
    |> Agent.get(& &1)
    |> Enum.count(&(elem(&1, 0) == prompt_id))
  end

  defp set_max_iterations(root, iterations) do
    path = Path.join(root, "prompt_runner_packet.md")

    path
    |> File.read!()
    |> String.replace("max_iterations: 4", "max_iterations: #{iterations}")
    |> then(&File.write!(path, &1))
  end

  defp set_default_action(root, action) do
    path = Path.join(root, "prompt_runner_packet.md")

    path
    |> File.read!()
    |> String.replace("default_action: \"continue\"", "default_action: \"#{action}\"")
    |> then(&File.write!(path, &1))
  end
end
