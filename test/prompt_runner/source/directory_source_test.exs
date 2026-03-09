defmodule PromptRunner.Source.DirectorySourceTest do
  use ExUnit.Case, async: true

  alias PromptRunner.Source.DirectorySource
  alias PromptRunner.Source.Result

  defp tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  test "loads numbered .prompt.md files, front matter, and heading fallbacks" do
    prompt_dir = tmp_dir("prompt_runner_directory_source")

    File.write!(
      Path.join(prompt_dir, "02_tests.prompt.md"),
      """
      ---
      num: 02
      phase: 2
      sp: 5
      targets: [app]
      commit: "test: harden auth flows"
      validation:
        - mix test
        - mix compile --warnings-as-errors
      ---
      # Harden auth flows

      ## Mission

      Expand test coverage for auth flows.
      """
    )

    File.write!(
      Path.join(prompt_dir, "01_auth.prompt.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.

      ## Validation Commands

      - `mix test`
      """
    )

    assert {:ok, %Result{} = result} = DirectorySource.load(prompt_dir, [])

    assert Enum.map(result.prompts, & &1.num) == ["01", "02"]

    first = Enum.at(result.prompts, 0)
    second = Enum.at(result.prompts, 1)

    assert first.name == "Reconcile auth ownership"
    assert first.commit_message =~ "Align the auth architecture"
    assert first.validation_commands == ["mix test"]

    assert second.phase == 2
    assert second.sp == 5
    assert second.target_repos == ["app"]
    assert second.validation_commands == ["mix test", "mix compile --warnings-as-errors"]
    assert result.commit_messages[{"02", nil}] == "test: harden auth flows"
  end

  test "falls back to generic markdown files when no .prompt.md files exist" do
    prompt_dir = tmp_dir("prompt_runner_directory_source_fallback")

    File.write!(
      Path.join(prompt_dir, "01_auth.md"),
      """
      # Reconcile auth ownership

      ## Mission

      Align the auth architecture across code and docs.
      """
    )

    assert {:ok, %Result{} = result} = DirectorySource.load(prompt_dir, [])
    assert length(result.prompts) == 1
    assert Enum.at(result.prompts, 0).num == "01"
  end
end
