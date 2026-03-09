defmodule PromptRunner.CLIV2Test do
  use ExUnit.Case, async: false

  alias PromptRunner.CLI

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "list command works with a prompt directory and does not require --config" do
    prompt_dir = tmp_dir("prompt_runner_cli_prompts")
    repo_dir = tmp_dir("prompt_runner_cli_repo")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "list",
                   prompt_dir,
                   "--target",
                   repo_dir,
                   "--provider",
                   "claude",
                   "--model",
                   "haiku"
                 ])
      end)

    assert output =~ "Implementation Prompts"
    assert output =~ "01 - Reconcile auth ownership"
  end

  test "scaffold command generates explicit config files from a prompt directory" do
    prompt_dir = tmp_dir("prompt_runner_cli_scaffold_prompts")
    repo_dir = tmp_dir("prompt_runner_cli_scaffold_repo")
    output_dir = tmp_dir("prompt_runner_cli_scaffold_output")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    ExUnit.CaptureIO.capture_io(fn ->
      assert :ok =
               CLI.main([
                 "scaffold",
                 prompt_dir,
                 "--output",
                 output_dir,
                 "--target",
                 repo_dir,
                 "--provider",
                 "claude",
                 "--model",
                 "haiku"
               ])
    end)

    assert File.exists?(Path.join(output_dir, "prompts.txt"))
    assert File.exists?(Path.join(output_dir, "commit-messages.txt"))
    assert File.exists?(Path.join(output_dir, "runner_config.exs"))
    assert File.exists?(Path.join(output_dir, "run_prompts.exs"))
  end
end
