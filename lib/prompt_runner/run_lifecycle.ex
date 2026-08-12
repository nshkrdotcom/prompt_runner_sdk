defmodule PromptRunner.RunLifecycle do
  @moduledoc """
  Durable run identity and immutable selection fences.

  An incomplete run may be resumed only inside its original resolved prompt
  set. This makes an omitted or changed selector incapable of widening a retry.
  """

  alias PromptRunner.Plan
  alias PromptRunner.RunJournal

  @active_states ~w(starting running failed faulted stopping stop_incomplete)
  @fingerprint_prompt_fields ~w(
    num phase sp name body target_repos commit_message template references required_reading
    context_files depends_on validation_commands verify metadata
  )a

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          run_dir: String.t() | nil,
          journal_path: String.t() | nil,
          snapshot_path: String.t() | nil,
          current_path: String.t() | nil,
          targets: [String.t()],
          upper_fence: String.t() | nil,
          ephemeral?: boolean()
        }

  defstruct [
    :run_id,
    :run_dir,
    :journal_path,
    :snapshot_path,
    :current_path,
    :upper_fence,
    targets: [],
    ephemeral?: false
  ]

  @spec open(Plan.t(), [String.t()], map()) :: {:ok, t()} | {:error, term()}
  def open(%Plan{state_dir: nil}, targets, _selection) do
    {:ok, %__MODULE__{targets: targets, upper_fence: List.last(targets), ephemeral?: true}}
  end

  def open(%Plan{state_dir: state_dir} = plan, targets, selection) when is_binary(state_dir) do
    root = Path.join(state_dir, "runs")
    current_path = Path.join(root, "current.json")

    with :ok <- File.mkdir_p(root),
         {:ok, current} <- read_snapshot(current_path) do
      cond do
        explicit_new_run?(selection) and resumable?(current) ->
          supersede_and_create(plan, current_path, current, targets, selection)

        resumable?(current) ->
          resume(plan, current_path, current, targets, selection)

        true ->
          create(plan, current_path, targets, selection)
      end
    end
  end

  @spec transition(t(), String.t(), map()) :: :ok | {:error, term()}
  def transition(run, state, data \\ %{})

  def transition(%__MODULE__{ephemeral?: true}, _state, _data), do: :ok

  def transition(%__MODULE__{} = run, state, data) when is_binary(state) and is_map(data) do
    with {:ok, seq} <- RunJournal.append(run.journal_path, run.run_id, "run_#{state}", data),
         {:ok, snapshot} <- read_snapshot(run.snapshot_path),
         updated = %{
           snapshot
           | "state" => state,
             "last_seq" => seq,
             "updated_at" => timestamp()
         },
         :ok <- write_snapshot(run.snapshot_path, updated) do
      write_snapshot(run.current_path, Map.put(updated, "snapshot_path", run.snapshot_path))
    end
  end

  defp create(plan, current_path, targets, selection, run_id \\ random_id()) do
    run_dir = Path.join(Path.dirname(current_path), run_id)
    journal_path = Path.join(run_dir, "journal.jsonl")
    snapshot_path = Path.join(run_dir, "current.json")
    upper_fence = List.last(targets)

    snapshot = %{
      "schema" => "prompt_runner.run/v1",
      "run_id" => run_id,
      "state" => "starting",
      "packet_fingerprint" => packet_fingerprint(plan),
      "selection" => %{
        "targets" => targets,
        "upper_fence" => upper_fence,
        "selectors" => stringify(selection)
      },
      "created_at" => timestamp(),
      "updated_at" => timestamp(),
      "last_seq" => 0
    }

    with :ok <- File.mkdir_p(run_dir),
         {:ok, seq} <- RunJournal.append(journal_path, run_id, "run_created", snapshot),
         snapshot = Map.put(snapshot, "last_seq", seq),
         :ok <- write_snapshot(snapshot_path, snapshot),
         :ok <- write_snapshot(current_path, Map.put(snapshot, "snapshot_path", snapshot_path)) do
      {:ok,
       %__MODULE__{
         run_id: run_id,
         run_dir: run_dir,
         journal_path: journal_path,
         snapshot_path: snapshot_path,
         current_path: current_path,
         targets: targets,
         upper_fence: upper_fence
       }}
    end
  end

  defp supersede_and_create(plan, current_path, current, targets, selection) do
    new_run_id = random_id()
    old_snapshot_path = current["snapshot_path"]
    old_journal_path = Path.join(Path.dirname(old_snapshot_path), "journal.jsonl")

    with {:ok, seq} <-
           RunJournal.append(old_journal_path, current["run_id"], "run_superseded", %{
             "reason" => "explicit_new_run",
             "new_run_id" => new_run_id,
             "new_packet_fingerprint" => packet_fingerprint(plan)
           }),
         superseded =
           current
           |> Map.put("state", "superseded")
           |> Map.put("last_seq", seq)
           |> Map.put("updated_at", timestamp()),
         :ok <- write_snapshot(old_snapshot_path, Map.delete(superseded, "snapshot_path")),
         :ok <- write_snapshot(current_path, superseded) do
      create(plan, current_path, targets, selection, new_run_id)
    end
  end

  defp resume(plan, current_path, current, requested_targets, selection) do
    original = get_in(current, ["selection", "targets"]) || []
    outside = requested_targets -- original

    cond do
      current["packet_fingerprint"] != packet_fingerprint(plan) ->
        {:error, :run_packet_fingerprint_changed}

      outside != [] ->
        {:error, {:selection_fence_widening, outside}}

      true ->
        targets = Enum.filter(original, &(&1 in requested_targets))
        snapshot_path = current["snapshot_path"]
        run_dir = Path.dirname(snapshot_path)
        journal_path = Path.join(run_dir, "journal.jsonl")

        with {:ok, seq} <-
               RunJournal.append(journal_path, current["run_id"], "run_resumed", %{
                 "targets" => targets,
                 "selectors" => stringify(selection)
               }),
             updated =
               current
               |> Map.put("state", "starting")
               |> Map.put("last_seq", seq)
               |> Map.put("updated_at", timestamp()),
             :ok <- write_snapshot(snapshot_path, Map.delete(updated, "snapshot_path")),
             :ok <- write_snapshot(current_path, updated) do
          {:ok,
           %__MODULE__{
             run_id: current["run_id"],
             run_dir: run_dir,
             journal_path: journal_path,
             snapshot_path: snapshot_path,
             current_path: current_path,
             targets: targets,
             upper_fence: get_in(current, ["selection", "upper_fence"])
           }}
        end
    end
  end

  defp resumable?(%{"state" => state, "run_id" => run_id, "snapshot_path" => path})
       when state in @active_states and is_binary(run_id) and is_binary(path),
       do: true

  defp resumable?(_current), do: false

  defp explicit_new_run?(selection),
    do: selection[:new_run] == true or selection["new_run"] == true

  defp read_snapshot(path) do
    case File.read(path) do
      {:ok, contents} ->
        case Jason.decode(contents) do
          {:ok, snapshot} when is_map(snapshot) -> {:ok, snapshot}
          _other -> {:error, {:run_snapshot_invalid, path}}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, {:run_snapshot_unreadable, path, reason}}
    end
  end

  defp write_snapshot(path, snapshot) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, Jason.encode!(snapshot, pretty: true), [:binary, :sync]) do
        File.rename(temp, path)
      end
    after
      _ = File.rm(temp)
    end
  end

  defp packet_fingerprint(plan) do
    payload =
      {:prompt_runner_packet_fingerprint_v3,
       %{
         prompts:
           Enum.map(plan.prompts, fn prompt ->
             prompt |> Map.from_struct() |> Map.take(@fingerprint_prompt_fields)
           end),
         agent_control:
           Map.get(plan.options || %{}, :agent_control) ||
             Map.get(plan.options || %{}, "agent_control")
       }}

    :crypto.hash(:sha256, :erlang.term_to_binary(payload)) |> Base.encode16(case: :lower)
  end

  defp stringify(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), stringify(item)} end)

  defp stringify(value) when is_list(value), do: Enum.map(value, &stringify/1)
  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp random_id, do: :crypto.strong_rand_bytes(18) |> Base.url_encode64(padding: false)
  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
