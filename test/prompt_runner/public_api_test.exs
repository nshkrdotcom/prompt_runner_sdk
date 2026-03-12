defmodule PromptRunner.PublicAPITest do
  use ExUnit.Case, async: false

  import Mox

  alias PromptRunner
  alias PromptRunner.Committer.GitCommitter
  alias PromptRunner.Committer.NoopCommitter
  alias PromptRunner.Plan
  alias PromptRunner.Run
  alias PromptRunner.RuntimeStore.FileStore
  alias PromptRunner.RuntimeStore.MemoryStore
  alias PromptRunner.RuntimeStore.NoopStore
  alias PromptRunner.Source.DirectorySource

  setup :verify_on_exit!

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp repo_dir(prefix) do
    path = tmp_dir(prefix)
    System.cmd("git", ["init", "-q"], cd: path)
    System.cmd("git", ["config", "user.name", "Test"], cd: path)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: path)
    File.write!(Path.join(path, "README.md"), "# Repo\n")
    System.cmd("git", ["add", "README.md"], cd: path)
    System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)
    path
  end

  test "plan/2 builds a convention-driven plan for a prompt directory" do
    prompt_dir = tmp_dir("prompt_runner_public_api_prompts")
    repo = repo_dir("prompt_runner_public_api_repo")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    assert {:ok, %Plan{} = plan} =
             PromptRunner.plan(prompt_dir,
               target: repo,
               provider: :claude,
               model: "haiku"
             )

    assert plan.source == DirectorySource
    assert length(plan.prompts) == 1
    assert Enum.at(plan.prompts, 0).num == "01"
    assert elem(plan.runtime_store, 0) == MemoryStore
    assert elem(plan.committer, 0) == NoopCommitter
    assert plan.state_dir == nil
    assert plan.config.model == "haiku"
    assert plan.config.llm_sdk == :claude
  end

  test "plan/2 uses CLI defaults when interface is cli" do
    prompt_dir = tmp_dir("prompt_runner_public_api_cli_prompts")
    repo = repo_dir("prompt_runner_public_api_cli_repo")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    assert {:ok, %Plan{} = plan} =
             PromptRunner.plan(prompt_dir,
               interface: :cli,
               target: repo,
               provider: :claude,
               model: "haiku"
             )

    assert elem(plan.runtime_store, 0) == FileStore
    assert plan.state_dir == Path.join(prompt_dir, ".prompt_runner")
  end

  test "plan/2 accepts explicit runtime store and committer overrides" do
    prompt_dir = tmp_dir("prompt_runner_public_api_override_prompts")
    repo = repo_dir("prompt_runner_public_api_override_repo")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    assert {:ok, %Plan{} = plan} =
             PromptRunner.plan(prompt_dir,
               target: repo,
               provider: :claude,
               model: "haiku",
               runtime_store: :noop,
               committer: :git
             )

    assert elem(plan.runtime_store, 0) == NoopStore
    assert elem(plan.committer, 0) == GitCommitter
  end

  test "run_prompt/2 canonicalizes symlinked targets before invoking the LLM" do
    repo = repo_dir("prompt_runner_public_api_run_repo")

    repo_alias =
      Path.join(
        System.tmp_dir!(),
        "prompt_runner_public_api_run_repo_alias_#{System.unique_integer([:positive])}"
      )

    test_pid = self()

    assert :ok = File.ln_s(repo, repo_alias)
    on_exit(fn -> File.rm_rf!(repo_alias) end)

    Application.put_env(:prompt_runner, :llm_module, PromptRunner.LLMMock)
    on_exit(fn -> Application.delete_env(:prompt_runner, :llm_module) end)

    PromptRunner.LLMMock
    |> expect(:start_stream, fn llm, prompt ->
      assert llm.cwd == repo
      assert prompt =~ "hello.txt"

      stream = [
        %{type: :run_started, data: %{model: llm.model}},
        %{type: :message_streamed, data: %{delta: "ok"}},
        %{type: :run_completed, data: %{stop_reason: "end_turn"}}
      ]

      {:ok, stream, fn -> :ok end, %{sdk: llm.sdk, model: llm.model, cwd: llm.cwd}}
    end)

    assert {:ok, %Run{} = run} =
             ExUnit.CaptureIO.capture_io(fn ->
               send(
                 test_pid,
                 {:run_result,
                  PromptRunner.run_prompt(
                    "Create hello.txt with a greeting.",
                    target: repo_alias,
                    provider: :claude,
                    model: "haiku",
                    on_event: fn event -> send(test_pid, {:observer_event, event.type}) end
                  )}
               )
             end)
             |> then(fn _ ->
               assert_receive {:run_result, result}
               result
             end)

    assert run.status == :ok
    assert_receive {:observer_event, :plan_built}
    assert_receive {:observer_event, :prompt_started}
    assert_receive {:observer_event, :run_started}
    assert_receive {:observer_event, :prompt_completed}
    assert_receive {:observer_event, :run_completed}

    refute File.exists?(Path.join(repo, ".prompt_runner"))
  end
end
