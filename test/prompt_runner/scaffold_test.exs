defmodule PromptRunner.ScaffoldTest do
  use ExUnit.Case, async: true

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "generated runner installs only the selected provider sdk deps" do
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

    assert runner =~ ~s({:prompt_runner_sdk, "~> 0.5.1"})
    assert runner =~ ~s({:claude_agent_sdk, "~> 0.17.0"})
    refute runner =~ "codex_sdk"
    refute runner =~ "gemini_cli_sdk"
    refute runner =~ "amp_sdk"
  end

  test "generated runner includes base and overridden provider sdk deps in stable order" do
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

    expected_lines = [
      ~s({:claude_agent_sdk, "~> 0.17.0"}),
      ~s({:codex_sdk, "~> 0.16.1"}),
      ~s({:gemini_cli_sdk, "~> 0.2.0"}),
      ~s({:amp_sdk, "~> 0.5.0"})
    ]

    Enum.each(expected_lines, fn line ->
      assert runner =~ line
    end)

    positions =
      Enum.map(expected_lines, fn line ->
        {position, _length} = :binary.match(runner, line)
        position
      end)

    assert positions == Enum.sort(positions)
  end
end
