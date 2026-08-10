defmodule PromptRunner.Git do
  @moduledoc """
  Git commit helpers for single-repo and multi-repo prompt runs, plus the
  read-only repository inspection used by the verifier and by `watch`.

  Everything in the inspection surface uses `git -C <root>` rather than the
  `:cd` option so a path that does not exist reports a git error instead of
  raising, and nothing in it writes: not the working tree, not the index, not a
  local branch, and not a remote-tracking ref.
  """

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Plan
  alias PromptRunner.UI

  @type source :: Plan.t() | Config.t()

  @doc "Returns true when `root` is inside a git work tree."
  @spec worktree?(String.t()) :: boolean()
  def worktree?(root) when is_binary(root) do
    case cmd(root, ["rev-parse", "--is-inside-work-tree"]) do
      {output, 0} -> String.trim(output) == "true"
      _other -> false
    end
  end

  @doc """
  Returns the trimmed `git status --porcelain` lines for `root`.

  An empty list means the working tree is clean.
  """
  @spec status_lines(String.t()) :: {:ok, [String.t()]} | {:error, String.t()}
  def status_lines(root) when is_binary(root) do
    case cmd(root, ["status", "--porcelain"]) do
      {output, 0} -> {:ok, output |> String.split("\n", trim: true) |> Enum.map(&String.trim/1)}
      {output, _code} -> {:error, String.trim(output)}
    end
  end

  @doc "Returns the number of commits reachable from HEAD, or nil when unavailable."
  @spec commit_count(String.t()) :: non_neg_integer() | nil
  def commit_count(root) when is_binary(root) do
    case value(root, ["rev-list", "--count", "HEAD"]) do
      nil -> nil
      count -> parse_count(count)
    end
  end

  @doc "Runs a git command in `root` and returns `{output, exit_code}`."
  @spec cmd(String.t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def cmd(root, args) when is_binary(root) and is_list(args) do
    System.cmd("git", ["-C", root | args], stderr_to_stdout: true)
  end

  @doc "Runs a git command in `root` and returns its trimmed output, or nil on failure."
  @spec value(String.t(), [String.t()]) :: String.t() | nil
  def value(root, args) when is_binary(root) and is_list(args) do
    case cmd(root, args) do
      {output, 0} -> String.trim(output)
      _other -> nil
    end
  end

  @doc """
  Returns the upstream ref for the current branch (for example `origin/main`),
  or nil when the branch has no upstream configured.
  """
  @spec upstream_ref(String.t()) :: String.t() | nil
  def upstream_ref(root) when is_binary(root) do
    value(root, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
  end

  @doc """
  Resolves `ref` on `remote` and returns its object id, under a bounded timeout.

  `git ls-remote` is a pure query: it opens a connection, reads the remote's ref
  advertisement, and writes nothing. Unlike `git fetch` it does not create or
  move remote-tracking refs, so a verify clause built on it cannot alter the
  repository it is judging — a gate that mutates anything in its subject is a
  gate that can change the thing it measures.

  The timeout matters because a verify clause runs after the model work is
  already spent: an unreachable remote must not hang the run.

  Returns `{:error, :ref_absent}` when the remote has no such ref.
  """
  @spec ls_remote(String.t(), String.t(), String.t(), timeout()) ::
          {:ok, String.t()} | {:error, term()}
  def ls_remote(root, remote, ref, timeout_ms)
      when is_binary(root) and is_binary(remote) and is_binary(ref) and is_integer(timeout_ms) do
    case bounded_cmd(root, ["ls-remote", "--exit-code", remote, ref], timeout_ms) do
      {:ok, output, 0} -> parse_ls_remote(output)
      {:ok, _output, 2} -> {:error, :ref_absent}
      {:ok, output, code} -> {:error, {:exit_status, code, first_line(output)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # `Task.shutdown/2` unlinks before killing, so a timeout closes the port and
  # takes the git process with it without disturbing the caller.
  defp bounded_cmd(root, args, timeout_ms) do
    task = Task.async(fn -> safe_cmd(root, args) end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _other -> {:error, {:timeout, timeout_ms}}
    end
  end

  defp parse_ls_remote(output) do
    case output |> String.split(~r/\s+/, trim: true) |> List.first() do
      sha when is_binary(sha) and sha != "" -> {:ok, sha}
      _other -> {:error, :ref_absent}
    end
  end

  defp safe_cmd(root, args) do
    {output, code} = cmd(root, args)
    {:ok, output, code}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp first_line(output) do
    output
    |> String.split("\n", trim: true)
    |> List.first()
    |> Kernel.||("")
    |> String.trim()
  end

  defp parse_count(count) do
    case Integer.parse(count) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  @spec commit_multi_repo(source(), String.t(), list({String.t(), String.t()})) ::
          list({String.t(), term()})
  def commit_multi_repo(source, num, target_repos) do
    Enum.map(target_repos, fn {repo_name, repo_path} ->
      msg = CommitMessages.get_message(source, num, repo_name)

      unless msg do
        raise "Commit message not found for prompt #{num}:#{repo_name}"
      end

      IO.puts("")
      IO.puts("#{UI.yellow("Checking")} #{repo_name} (#{repo_path})...")
      result = commit_repo(repo_path, msg, num, repo_name)
      {repo_name, result}
    end)
  end

  @spec commit_single_repo(source(), String.t(), String.t(), String.t() | nil) ::
          {:ok, String.t()} | {:skip, atom()} | {:error, atom()}
  def commit_single_repo(source, num, repo_name \\ "default", repo_path \\ nil) do
    path = repo_path || project_dir(source)

    # Try repo-specific message first, fall back to generic
    msg =
      if repo_name != "default" do
        CommitMessages.get_message(source, num, repo_name) ||
          CommitMessages.get_message(source, num)
      else
        CommitMessages.get_message(source, num)
      end

    unless msg do
      raise "Commit message not found for prompt #{num}"
    end

    commit_repo(path, msg, num, repo_name)
  end

  @spec commit_repo(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:skip, atom()} | {:error, atom()}
  def commit_repo(project_dir, msg, num, repo_name) do
    {status, exit_status} = System.cmd("git", ["status", "--porcelain"], cd: project_dir)

    cond do
      exit_status != 0 ->
        IO.puts(UI.red("ERROR: git status failed for #{repo_name}"))
        {:error, :git_status_failed}

      String.trim(status) == "" ->
        IO.puts(UI.dim("No changes in #{repo_name}"))
        {:skip, :no_changes}

      true ->
        IO.puts(UI.yellow("Committing to #{repo_name}..."))

        {_, 0} = System.cmd("git", ["add", "-A"], cd: project_dir)

        tmp_dir = System.tmp_dir!()
        tmp_id = System.unique_integer([:positive])
        tmp_path = Path.join(tmp_dir, "prompt-#{num}-#{repo_name}-commit-msg-#{tmp_id}.txt")
        File.write!(tmp_path, msg <> "\n")

        {_, exit_code} = System.cmd("git", ["commit", "--file", tmp_path], cd: project_dir)
        File.rm(tmp_path)

        if exit_code == 0 do
          {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: project_dir)
          short = sha |> String.trim() |> String.slice(0, 8)
          IO.puts(UI.green("Committed to #{repo_name}: #{short}"))
          {:ok, String.trim(sha)}
        else
          IO.puts(UI.red("ERROR: Git commit failed for #{repo_name}"))
          {:error, :commit_failed}
        end
    end
  end

  defp project_dir(%Plan{config: config}), do: project_dir(config)
  defp project_dir(%Config{project_dir: project_dir}), do: project_dir
end
