defmodule PromptRunner.ScaffoldTest do
  use ExUnit.Case, async: true

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "generated runner installs only prompt_runner_sdk" do
    prompt_dir = tmp_dir("prompt_runner_scaffold_prompts")
    repo_dir = tmp_dir("prompt_runner_scaffold_repo")
    output_dir = tmp_dir("prompt_runner_scaffold_output")

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      "# Reconcile auth\n\n## Mission\n\nAlign auth.\n"
    )

    assert {:ok, %{runner_file: runner_file}} =
             PromptRunner.scaffold(prompt_dir,
               output: output_dir,
               target: repo_dir,
               provider: :claude,
               model: "haiku"
             )

    runner = File.read!(runner_file)

    assert runner =~ ~s({:prompt_runner_sdk, "~> 0.6.1"})
    refute runner =~ "claude_agent_sdk"
    refute runner =~ "codex_sdk"
    refute runner =~ "gemini_cli_sdk"
    refute runner =~ "amp_sdk"
  end

  test "generated runner stays provider-agnostic even with overrides" do
    prompt_dir = tmp_dir("prompt_runner_scaffold_multi_prompts")
    repo_dir = tmp_dir("prompt_runner_scaffold_multi_repo")
    output_dir = tmp_dir("prompt_runner_scaffold_multi_output")

    Enum.each(1..3, fn index ->
      num = String.pad_leading(Integer.to_string(index), 2, "0")

      File.write!(
        Path.join(prompt_dir, "#{num}_task.prompt.md"),
        """
        # Task #{num}

        ## Mission

        Complete task #{num}.
        """
      )
    end)

    assert {:ok, %{runner_file: runner_file}} =
             PromptRunner.scaffold(prompt_dir,
               output: output_dir,
               target: repo_dir,
               provider: :amp,
               model: "sonnet",
               prompt_overrides: %{
                 "01" => %{provider: "claude"},
                 "02" => %{provider: "codex"},
                 "03" => %{provider: "gemini"}
               }
             )

    runner = File.read!(runner_file)

    assert runner =~ ~s({:prompt_runner_sdk, "~> 0.6.1"})
    refute runner =~ "claude_agent_sdk"
    refute runner =~ "codex_sdk"
    refute runner =~ "gemini_cli_sdk"
    refute runner =~ "amp_sdk"
  end
end
