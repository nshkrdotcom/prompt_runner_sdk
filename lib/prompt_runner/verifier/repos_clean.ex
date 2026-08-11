defmodule PromptRunner.Verifier.ReposClean do
  @moduledoc """
  The `repos_clean:` verify clause: assert that sessions committed their work.

  ```yaml
  verify:
    repos_clean:
      - repo: "app"
        pushed: true      # default false
  ```

  When a packet runs with `--no-commit`, the runner's committer never runs and
  each session is responsible for committing its own work. `changed_paths_only`
  is useless in that arrangement — it reads `git status --porcelain`, which is
  empty precisely because the session committed — so it passes vacuously.
  `repos_clean:` is the clause that actually holds such a packet to account.

  `pushed:` semantics:

  - `pushed: false` (the default) checks only that the working tree is clean. A
    branch with no upstream is fine, and an existing upstream is not compared.
    A repository that starts local and stays local until its author decides to
    publish it must not fail a gate for that.
  - `pushed: true` additionally requires an upstream. A missing upstream is a
    failure, not a pass: the clause was asked to assert publication and cannot.

  The default upstream comparison is local and bounded: it compares `HEAD` to
  the cached upstream ref that a successful `git push` updates. Verification
  therefore never turns a transient network outage into a failed prompt.
  `network: true` explicitly opts into a bounded `git ls-remote` query.

  The bound matters because a verify clause runs after the model work is
  already spent and an unreachable remote must not hang the run. When the
  remote cannot be reached, the comparison falls back to the cached
  remote-tracking ref and says so in `details`. That fallback is biased toward
  reporting *not pushed*, because a cached ref can only be behind the remote,
  never ahead of it — the safe direction for a clause whose whole job is to
  assert publication.
  """

  alias PromptRunner.Git

  @default_remote_timeout_ms 90_000
  @max_reported_paths 10

  @doc "Builds the verifier report item for one `repos_clean:` entry."
  @spec report(String.t() | nil, String.t() | nil, term()) :: map()
  def report(repo, nil, entry), do: missing_repo_report(repo, pushed?(entry))

  def report(repo, root, entry) do
    if Git.worktree?(root) do
      clean_report(repo, root, pushed?(entry), network?(entry), remote_timeout_ms(entry))
    else
      repo
      |> base(root, pushed?(entry))
      |> Map.merge(%{pass?: false, details: "not a git repository: #{root}"})
    end
  end

  @doc "Returns the checklist label for one `repos_clean:` entry."
  @spec label(term()) :: String.t()
  def label(entry) do
    if pushed?(entry) do
      "repo committed and pushed: #{entry_repo(entry)}"
    else
      "repo committed: #{entry_repo(entry)}"
    end
  end

  @doc "Returns the repo name declared by an entry, or nil when it is implicit."
  @spec entry_repo(term()) :: String.t() | nil
  def entry_repo(entry) when is_map(entry), do: Map.get(entry, "repo")
  def entry_repo(entry) when is_binary(entry), do: entry
  def entry_repo(entry), do: to_string(entry)

  defp pushed?(entry) when is_map(entry), do: Map.get(entry, "pushed") == true
  defp pushed?(_entry), do: false

  defp network?(entry) when is_map(entry), do: Map.get(entry, "network") == true
  defp network?(_entry), do: false

  defp remote_timeout_ms(entry) when is_map(entry) do
    case Map.get(entry, "remote_timeout_ms") || Map.get(entry, "fetch_timeout_ms") do
      value when is_integer(value) and value > 0 -> value
      _other -> @default_remote_timeout_ms
    end
  end

  defp remote_timeout_ms(_entry), do: @default_remote_timeout_ms

  defp missing_repo_report(repo, pushed?) do
    repo
    |> base(nil, pushed?)
    |> Map.merge(%{pass?: false, details: "missing_repo: #{repo || "(unnamed)"}"})
  end

  defp base(repo, root, pushed?) do
    %{
      kind: "repos_clean",
      repo: repo,
      path: root,
      pushed?: pushed?,
      branch: nil,
      head: nil,
      upstream: nil,
      dirty_count: 0
    }
  end

  defp clean_report(repo, root, pushed?, network?, timeout_ms) do
    branch = Git.value(root, ["rev-parse", "--abbrev-ref", "HEAD"])
    head = Git.value(root, ["rev-parse", "--short", "HEAD"])

    base =
      repo
      |> base(root, pushed?)
      |> Map.merge(%{branch: branch, head: head})

    case Git.status_lines(root) do
      {:error, output} ->
        Map.merge(base, %{pass?: false, details: "git status failed: #{output}"})

      {:ok, []} ->
        Map.merge(base, upstream_result(root, branch, head, pushed?, network?, timeout_ms))

      {:ok, dirty} ->
        Map.merge(base, %{
          dirty_count: length(dirty),
          pass?: false,
          details: dirty_details(dirty)
        })
    end
  end

  defp dirty_details(dirty) do
    shown = Enum.take(dirty, @max_reported_paths)
    omitted = length(dirty) - length(shown)
    suffix = if omitted > 0, do: ", and #{omitted} more", else: ""

    "uncommitted changes (#{length(dirty)}): #{Enum.join(shown, ", ")}#{suffix}"
  end

  defp upstream_result(root, branch, head, pushed?, network?, timeout_ms) do
    upstream_verdict(root, branch, head, Git.upstream_ref(root), pushed?, network?, timeout_ms)
  end

  defp upstream_verdict(_root, branch, head, nil, true, _network?, _timeout_ms) do
    %{
      pass?: false,
      details: "no upstream for branch #{branch} at #{head}; pushed: true requires one"
    }
  end

  defp upstream_verdict(_root, branch, head, nil, _pushed?, _network?, _timeout_ms) do
    %{pass?: true, details: "ok: #{branch} at #{head} (local only, no upstream)"}
  end

  defp upstream_verdict(_root, branch, head, upstream, false, _network?, _timeout_ms) do
    %{
      upstream: upstream,
      pass?: true,
      details: "ok: #{branch} at #{head} (upstream #{upstream}, push not asserted)"
    }
  end

  defp upstream_verdict(root, branch, head, upstream, true, network?, timeout_ms) do
    local_sha = Git.value(root, ["rev-parse", "HEAD"])
    {upstream_sha, note} = upstream_head(root, upstream, network?, timeout_ms)

    upstream
    |> pushed_verdict(branch, head, local_sha, upstream_sha)
    |> Map.update!(:details, &(&1 <> note))
  end

  defp upstream_head(root, upstream, false, _timeout_ms) do
    {Git.value(root, ["rev-parse", upstream]),
     " [compared with cached upstream; network disabled]"}
  end

  defp upstream_head(root, upstream, true, timeout_ms),
    do: remote_head(root, upstream, timeout_ms)

  # Ask the remote. Falling back to the cached remote-tracking ref keeps a
  # transient network failure from being reported as a verdict nobody
  # established, and the note says which of the two answered.
  defp remote_head(root, upstream, timeout_ms) do
    {remote, ref} = remote_and_ref(upstream)

    case Git.ls_remote(root, remote, ref, timeout_ms) do
      {:ok, sha} -> {sha, ""}
      {:error, :ref_absent} -> {nil, " [#{ref} is absent from #{remote}]"}
      {:error, reason} -> {Git.value(root, ["rev-parse", upstream]), unreachable_note(reason)}
    end
  end

  defp unreachable_note({:timeout, ms}) do
    " [#{remote_query_label()} timed out after #{ms}ms; compared against the cached " <>
      "remote-tracking ref, which can only be behind the remote]"
  end

  defp unreachable_note(reason) do
    " [#{remote_query_label()} failed (#{inspect(reason)}); compared against the cached " <>
      "remote-tracking ref, which can only be behind the remote]"
  end

  defp remote_query_label, do: "git ls-remote"

  defp remote_and_ref(upstream) do
    case String.split(upstream, "/", parts: 2) do
      [remote, branch] -> {remote, "refs/heads/" <> branch}
      [remote] -> {remote, "HEAD"}
    end
  end

  defp pushed_verdict(upstream, branch, head, sha, sha) when is_binary(sha) do
    %{
      upstream: upstream,
      pass?: true,
      details: "ok: #{branch} at #{head} (pushed to #{upstream})"
    }
  end

  defp pushed_verdict(upstream, branch, head, _local_sha, upstream_sha) do
    %{
      upstream: upstream,
      pass?: false,
      details:
        "not pushed: #{branch} HEAD #{head} does not match #{upstream} #{short(upstream_sha)}"
    }
  end

  defp short(nil), do: "(unresolved)"
  defp short(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
end
