defmodule PromptRunner.Control do
  @moduledoc """
  Watch a live run, and change how it renders, without attaching to it.

  A packet run used to be a black box while it ran: you could read its output
  and you could kill it, and that was the whole interface. This is the other
  half — a process-addressable API with no IO, no terminal, and no assumption
  about who is calling. The CLI's `control` commands are written entirely
  against this module, and a Phoenix LiveView would use exactly the same
  functions.

  ## Addressing a run

  A `run_ref` is `{packet_dir, run_id}`. Explicit ids rather than an implicit
  "current run" cost nothing now and avoid a rewrite if the runner ever goes
  concurrent. `current_run/1` finds the newest one for a packet:

      {:ok, run_ref} = PromptRunner.Control.current_run("packets/demo")
      {:ok, snapshot} = PromptRunner.Control.snapshot(run_ref)

  ## Reading

  `snapshot/1` and `log/1` read files the runner writes. They never touch the
  session, so polling them cannot slow, block, or crash the run.

  ## Writing

  `set_view/2` writes a request into `control/requests/`. The runner consumes
  it at an event boundary — never mid-event — applies it, and records the
  outcome in `control/log.jsonl`. `:ok` means the request was accepted for
  delivery, not that it has been applied yet; the log is where the outcome
  lives. That asynchrony is deliberate: it is what stops an in-VM caller from
  quietly getting a privileged synchronous path the CLI does not have.

  ## Subscribing

  `subscribe/3` follows the run's canonical event stream:

      {:ok, ref} = PromptRunner.Control.subscribe(run_ref, self())

      receive do
        {:prompt_runner_event, ^ref, event} -> IO.inspect(event["type"])
        {:prompt_runner_control, ^ref, {:run_finished, status}} -> status
      end

  Events arrive as they were written, so maps with string keys.
  """

  alias PromptRunner.Control.{Entry, Snapshot, Store, Subscriber}

  @type run_ref :: {packet_dir :: String.t(), run_id :: String.t()}

  @doc """
  The newest run recorded for `packet_dir`, running or not.

  Returns `{:error, :no_run}` when the packet has no control directory yet,
  which is the ordinary state of a packet nothing has ever run.
  """
  @spec current_run(String.t()) :: {:ok, run_ref()} | {:error, term()}
  def current_run(packet_dir) when is_binary(packet_dir) do
    case Store.read_snapshot(packet_dir) do
      {:ok, %Snapshot{run_id: run_id}} when is_binary(run_id) -> {:ok, {packet_dir, run_id}}
      {:ok, %Snapshot{}} -> {:error, :no_run}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The current state of the run: prompt, attempt, mode, elapsed, provider,
  model, tool count, token totals, and the view settings in force.
  """
  @spec snapshot(run_ref()) :: {:ok, Snapshot.t()} | {:error, term()}
  def snapshot({packet_dir, run_id}) when is_binary(packet_dir) and is_binary(run_id) do
    with {:ok, %Snapshot{} = snapshot} <- Store.read_snapshot(packet_dir) do
      if snapshot.run_id == run_id do
        {:ok, snapshot}
      else
        {:error, {:stale_run, snapshot.run_id}}
      end
    end
  end

  @doc """
  Changes how a running run renders, from outside it.

  Accepts `log_mode`, `tool_output`, `thinking`, and `diff`. These are already renderer
  state; this makes them mutable at runtime rather than only at launch. An
  unknown key or value is refused here rather than written and ignored.

  Options:

  - `:author` — recorded on the log entry, defaults to the OS user
  """
  @spec set_view(run_ref(), map() | keyword(), keyword()) :: :ok | {:error, term()}
  def set_view(run_ref, view, opts \\ [])

  def set_view({packet_dir, run_id}, view, opts) do
    with {:ok, normalized} <- Snapshot.normalize_view(view) do
      submit(packet_dir, run_id, "set_view", stringify(normalized), opts)
    end
  end

  @doc """
  Says something to the agent while it is working.

  Steering changes *how* the agent works toward an unchanged definition of
  done — "you're down a rabbit hole, check `dependency_sources.exs` before you
  keep editing mix files". The verify contract is untouched: the prompt still
  passes or fails on exactly the criteria it started with, which is what makes
  steering safe to allow freely and amendment (`amend/4`) not.

  A steer is never evidence. A contract asserting a document contains X is not
  satisfied by a human having said "put X in the doc" — the verifier sees what
  the session produced, not what it was told.

  A steer is always recorded, twice: on the control log, and as an append-only
  artifact at `packet/.prompt_runner/interventions/<prompt>.jsonl` that is
  committed with the work. The prompt's result records that it was steered and
  how many times, so a human-guided result is distinguishable from an
  autonomous one — flagged, not disqualified.

  Options:

  - `:author` — recorded on both records, defaults to the OS user
  """
  @spec steer(run_ref(), String.t(), keyword()) :: :ok | {:error, term()}
  def steer(run_ref, text, opts \\ [])

  def steer({packet_dir, run_id}, text, opts) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_steer}
      trimmed -> submit(packet_dir, run_id, "steer", %{"text" => trimmed}, opts)
    end
  end

  @doc """
  Interrupts the current turn and resumes the same provider thread.

  Not a hold on the process. A pause has no bounded duration — the reason to
  pause is to think, or to stop for the night — and holding the provider
  process open dies silently to provider idle limits and to `run_deadline_ms`,
  with the death discovered only on resume. So this interrupts the turn and
  resumes the thread, which is the machinery steering builds anyway.
  """
  @spec pause(run_ref(), keyword()) :: :ok | {:error, term()}
  def pause(run_ref, opts \\ [])

  def pause({packet_dir, run_id}, opts) do
    submit(packet_dir, run_id, "pause", %{}, opts)
  end

  @doc """
  Every command the plane has seen for this packet, oldest first.

  Includes refused commands. A refusal that leaves no trace is
  indistinguishable from a command that was never sent.
  """
  @spec log(run_ref()) :: {:ok, [Entry.t()]}
  def log({packet_dir, run_id}) do
    {:ok, entries} = Store.read_log(packet_dir)
    {:ok, Enum.filter(entries, &(&1.run_id in [nil, run_id]))}
  end

  @doc """
  Sends this run's events to `pid` until the run finishes or `pid` dies.

  Options:

  - `:from` — `:start` (default) replays the run from its first event, then
    follows; `:current` delivers only what arrives after subscribing
  - `:interval_ms` — poll interval, default 200
  """
  @spec subscribe(run_ref(), pid(), keyword()) :: {:ok, reference()} | {:error, term()}
  def subscribe({packet_dir, run_id}, pid, opts \\ []) when is_pid(pid) do
    ref = make_ref()

    start_opts =
      opts
      |> Keyword.take([:from, :interval_ms])
      |> Keyword.merge(packet_dir: packet_dir, run_id: run_id, target: pid, ref: ref)

    case Subscriber.start_link(start_opts) do
      {:ok, subscriber} ->
        Process.put({__MODULE__, ref}, subscriber)
        {:ok, ref}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stops a subscription started by `subscribe/3` from the same process.

  A subscription also ends on its own when the run finishes or the subscribing
  process dies, so this is for a consumer that wants to stop watching earlier.
  """
  @spec unsubscribe(run_ref(), reference()) :: :ok
  def unsubscribe(_run_ref, ref) when is_reference(ref) do
    case Process.delete({__MODULE__, ref}) do
      pid when is_pid(pid) -> Subscriber.stop(pid)
      _other -> :ok
    end
  end

  # A request names the run it was issued against. The runner refuses one
  # naming a run that is no longer current, because a command aimed at a run
  # that has since ended must not silently land on its successor.
  defp submit(packet_dir, run_id, command, params, opts) do
    request = %{
      "command" => command,
      "params" => params,
      "run_id" => run_id,
      "author" => author(opts),
      "issued_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Store.write_request(packet_dir, request) do
      {:ok, _path} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp author(opts) do
    case Keyword.get(opts, :author) do
      author when is_binary(author) and author != "" -> author
      _other -> default_author()
    end
  end

  defp default_author do
    System.get_env("USER") || System.get_env("USERNAME") || "unknown"
  end

  defp stringify(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_string(value)} end)
  end
end
