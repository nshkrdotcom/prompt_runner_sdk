defmodule PromptRunner.Rendering.Studio.DiffTest do
  @moduledoc """
  Showing what a tool changed on disk.

  Two cases that must not be conflated: a patch carried in the event, which is
  the tool's own change; and a path carried in the event, where the only thing
  available is the file as it stands now. Rendering the second as if it were
  the first is the failure this guards against.
  """

  use ExUnit.Case, async: true

  alias PromptRunner.Rendering.Studio.Diff
  alias PromptRunner.Test.FSHelpers

  defp plain(iodata), do: iodata |> IO.iodata_to_binary() |> String.replace(~r/\e\[[0-9;]*m/, "")

  defp edit(input, name \\ "Edit"), do: %{name: name, input: input}

  describe "a patch carried in the event" do
    test "an Edit renders its own patch, with no filesystem access" do
      output =
        edit(%{
          "file_path" => "/nowhere/at/all/lib/thing.ex",
          "old_string" => "def run, do: :old\n",
          "new_string" => "def run, do: :new\n"
        })
        |> Diff.render(color: false)
        |> plain()

      assert output =~ "- def run, do: :old"
      assert output =~ "+ def run, do: :new"

      # The path does not exist and is not consulted. Naming a file that could
      # not be read and still getting the patch is the proof.
      refute File.exists?("/nowhere/at/all/lib/thing.ex")
    end

    test "a Write renders every line as added" do
      output =
        edit(%{"file_path" => "notes.md", "content" => "one\ntwo\n"}, "Write")
        |> Diff.render(color: false)
        |> plain()

      assert output =~ "+ one"
      assert output =~ "+ two"
      refute output =~ "- "
    end

    test "unchanged lines around the change are context, not additions" do
      output =
        edit(%{
          "file_path" => "a.ex",
          "old_string" => "keep\nold\ntail\n",
          "new_string" => "keep\nnew\ntail\n"
        })
        |> Diff.render(color: false)
        |> plain()

      assert output =~ "  keep"
      assert output =~ "- old"
      assert output =~ "+ new"
      assert output =~ "  tail"
    end

    test "the stat counts the lines that actually moved" do
      assert %{added: 1, removed: 1} =
               Diff.stat(
                 edit(%{
                   "file_path" => "a.ex",
                   "old_string" => "keep\nold\n",
                   "new_string" => "keep\nnew\n"
                 })
               )
    end

    test "the stat suffix is a summary-line fragment" do
      suffix =
        Diff.stat_suffix(
          edit(%{"file_path" => "a.ex", "old_string" => "", "new_string" => "a\nb\nc\n"})
        )

      assert suffix =~ "+4"
      assert suffix =~ "−0"
    end

    test "a tool call with no patch and no path has no stat and no body" do
      assert Diff.stat(%{name: "Bash", input: %{"command" => "ls"}}) == nil
      assert Diff.stat_suffix(%{name: "Bash", input: %{"command" => "ls"}}) == ""
      assert Diff.render(%{name: "Bash", input: %{"command" => "ls"}}, color: false) == []
    end

    test "atom-keyed tool input works as well as string-keyed" do
      output =
        %{name: "Edit", input: %{file_path: "a.ex", old_string: "x\n", new_string: "y\n"}}
        |> Diff.render(color: false)
        |> plain()

      assert output =~ "- x"
      assert output =~ "+ y"
    end
  end

  describe "truncation" do
    test "a long diff always carries its truncation marker" do
      content = Enum.map_join(1..200, "\n", &"line #{&1}")

      output =
        edit(%{"file_path" => "big.txt", "content" => content}, "Write")
        |> Diff.render(color: false, line_budget: 10)
        |> plain()

      assert output =~ "+ line 1"
      assert output =~ "+ line 10"
      refute output =~ "+ line 11\n"
      assert output =~ "[truncated: 190 more lines]"
    end

    test "a diff inside the budget carries no marker" do
      output =
        edit(%{"file_path" => "small.txt", "content" => "one\n"}, "Write")
        |> Diff.render(color: false, line_budget: 10)
        |> plain()

      refute output =~ "truncated"
    end
  end

  describe "a path carried in the event, with no patch" do
    setup do
      repo = FSHelpers.git_repo!("prompt_runner_diff_repo")
      on_exit(fn -> File.rm_rf!(repo) end)
      {:ok, repo: repo}
    end

    test "renders the current state and says so", %{repo: repo} do
      File.write!(Path.join(repo, "README.md"), "# Repo\nchanged by something\n")

      output =
        %{name: "Edit", input: %{"file_path" => "README.md"}}
        |> Diff.render(color: false, cwd: repo)
        |> plain()

      assert output =~ "+ changed by something"

      # The label is the whole point: after several edits in one turn this is
      # not the diff of the call being rendered, and must not read as if it is.
      assert output =~ "current state of README.md, not this call's change"
    end

    test "renders nothing when the file has no uncommitted change", %{repo: repo} do
      assert Diff.render(%{name: "Edit", input: %{"file_path" => "README.md"}},
               color: false,
               cwd: repo
             ) == []
    end

    test "renders nothing without a cwd to run git in" do
      assert Diff.render(%{name: "Edit", input: %{"file_path" => "README.md"}}, color: false) ==
               []
    end

    test "reads the Antigravity spelling of the path key", %{repo: repo} do
      File.write!(Path.join(repo, "README.md"), "# Repo\nagy wrote this\n")

      output =
        %{name: "replace_file_content", input: %{"TargetFile" => "README.md"}}
        |> Diff.render(color: false, cwd: repo)
        |> plain()

      assert output =~ "agy wrote this"
      assert output =~ "current state of README.md"
    end
  end
end
