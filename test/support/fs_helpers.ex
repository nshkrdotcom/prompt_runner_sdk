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

  @doc """
  Creates an empty bare repository usable as a local `origin`.

  Local bare repositories keep upstream-tracking assertions off the network.
  """
  def bare_repo!(prefix) do
    path = tmp_dir(prefix)
    System.cmd("git", ["init", "-q", "--bare"], cd: path)
    path
  end

  @doc "Runs git in `repo` and returns trimmed output, raising on a non-zero exit."
  def git!(repo, args) do
    case System.cmd("git", args, cd: repo, stderr_to_stdout: true) do
      {output, 0} ->
        String.trim(output)

      {output, code} ->
        raise "git #{Enum.join(args, " ")} failed in #{repo} (#{code}):\n#{output}"
    end
  end

  @doc "Writes `contents` to `relative_path` inside `repo` and commits it."
  def commit_file!(repo, relative_path, contents) do
    full_path = Path.join(repo, relative_path)
    File.mkdir_p!(Path.dirname(full_path))
    File.write!(full_path, contents)
    git!(repo, ["add", relative_path])
    git!(repo, ["commit", "-q", "-m", "add #{relative_path}"])
    :ok
  end

  @doc "Adds `remote` as `origin` and pushes the current branch with upstream tracking."
  def push_to_origin!(repo, remote) do
    git!(repo, ["remote", "add", "origin", remote])
    branch = git!(repo, ["rev-parse", "--abbrev-ref", "HEAD"])
    git!(repo, ["push", "-q", "-u", "origin", branch])
    branch
  end

  @doc """
  Writes a packet manifest and prompt files under a fresh packet root.

  `prompts` is a list of `{filename, contents}` pairs.
  """
  def packet!(prefix, manifest, prompts) do
    root = tmp_dir(prefix)
    File.mkdir_p!(Path.join(root, "prompts"))
    File.write!(Path.join(root, "prompt_runner_packet.md"), manifest)

    Enum.each(prompts, fn {file, contents} ->
      File.write!(Path.join([root, "prompts", file]), contents)
    end)

    root
  end
end
