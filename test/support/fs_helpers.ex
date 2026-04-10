defmodule PromptRunner.Test.FSHelpers do
  @moduledoc false

  def tmp_dir(prefix) do
    path = Path.join(System.tmp_dir!(), "#{prefix}_#{System.unique_integer([:positive])}")
    File.mkdir_p!(path)
    path
  end

  def git_repo!(prefix) do
    path = tmp_dir(prefix)
    System.cmd("git", ["init", "-q"], cd: path)
    System.cmd("git", ["config", "user.name", "Prompt Runner Test"], cd: path)
    System.cmd("git", ["config", "user.email", "prompt-runner@example.com"], cd: path)
    File.write!(Path.join(path, "README.md"), "# Repo\n")
    System.cmd("git", ["add", "README.md"], cd: path)
    System.cmd("git", ["commit", "-q", "-m", "initial"], cd: path)
    path
  end
end
