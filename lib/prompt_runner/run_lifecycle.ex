defmodule PromptRunner.RunLifecycle do
  @moduledoc """
  Durable run identity and immutable selection fences.

  An incomplete run may be resumed only inside its original resolved prompt
  set. This makes an omitted or changed selector incapable of widening a retry.
  """

  alias PromptRunner.Plan
  alias PromptRunner.RunJournal

  @active_states ~w(starting running failed faulted stopping stop_incomplete)

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
      if resumable?(current) do
        resume(plan, current_path, current, targets, selection)
      else
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

  defp create(plan, current_path, targets, selection) do
    run_id = random_id()
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
      {plan.source_root,
       Enum.map(plan.prompts, fn prompt ->
         {prompt.num, prompt.name, Map.get(prompt, :file)}
       end)}

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
