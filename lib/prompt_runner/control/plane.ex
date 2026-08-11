defmodule PromptRunner.Control.Plane do
  @moduledoc """
  The runner's half of the control plane.

  Holds one run's control state, maintains `snapshot.json` and the subscriber
  event stream, and consumes pending requests **at event boundaries** — never
  mid-event. A request that cannot be parsed, names an unknown command, or
  targets a run that is no longer current is logged and dropped; nothing
  arriving through this transport is ever fatal to a run.

  Consumers use `PromptRunner.Control`, not this module.

  A plan with no state directory — an in-memory API run — gets a disabled
  plane. Embedded use stays free of filesystem side effects, and every function
  here is a no-op returning the same state.
  """

  alias PromptRunner.Control.{Entry, Interventions, Snapshot, Store}

  @type command ::
          {:set_view, map()} | {:steer, String.t(), String.t() | nil} | {:pause, String.t() | nil}

  @type t :: %__MODULE__{
          packet_dir: String.t() | nil,
          snapshot: Snapshot.t(),
          run_started_mono: integer() | nil,
          prompt_started_mono: integer() | nil,
          max_steers: non_neg_integer()
        }

  defstruct packet_dir: nil,
            snapshot: %Snapshot{},
            run_started_mono: nil,
            prompt_started_mono: nil,
            max_steers: 0

  @doc """
  Opens the control plane for a run and writes its first snapshot.

  `packet_dir` of `nil` disables the plane.
  """
  @spec open(String.t() | nil, keyword()) :: t()
  def open(nil, _opts), do: %__MODULE__{}

  def open(packet_dir, opts) when is_binary(packet_dir) do
    now = DateTime.utc_now()

    snapshot = %Snapshot{
      run_id: Keyword.get_lazy(opts, :run_id, &generate_run_id/0),
      packet_dir: packet_dir,
      packet: Keyword.get(opts, :packet),
      status: :running,
      run_started_at: now,
      updated_at: now,
      view: Keyword.get(opts, :view, %Snapshot{}.view)
    }

    Store.init(packet_dir)
    Store.reset_events(packet_dir)

    %__MODULE__{
      packet_dir: packet_dir,
      snapshot: snapshot,
      run_started_mono: monotonic_ms(),
      max_steers: Keyword.get(opts, :max_steers, 0)
    }
    |> persist()
  end

  @spec run_id(t()) :: String.t() | nil
  def run_id(%__MODULE__{snapshot: %Snapshot{run_id: run_id}}), do: run_id

  @spec enabled?(t()) :: boolean()
  def enabled?(%__MODULE__{packet_dir: packet_dir}), do: is_binary(packet_dir)

  @spec steer_count(t()) :: non_neg_integer()
  def steer_count(%__MODULE__{snapshot: %Snapshot{steer_count: count}}), do: count

  @spec packet_dir(t()) :: String.t() | nil
  def packet_dir(%__MODULE__{packet_dir: packet_dir}), do: packet_dir

  @spec view(t()) :: Snapshot.view()
  def view(%__MODULE__{snapshot: %Snapshot{view: view}}), do: view

  @doc """
  Records that a prompt attempt has started, resetting the per-prompt counters.
  """
  @spec prompt_started(t(), map(), atom(), pos_integer(), map()) :: t()
  def prompt_started(%__MODULE__{packet_dir: nil} = plane, _prompt, _mode, _attempt, _llm),
    do: plane

  def prompt_started(%__MODULE__{} = plane, prompt, mode, attempt, llm) do
    snapshot = %{
      plane.snapshot
      | prompt_id: Map.get(prompt, :num),
        prompt_name: Map.get(prompt, :name),
        attempt: attempt,
        mode: mode,
        provider: Map.get(llm, :sdk) || Map.get(llm, :provider),
        model: Map.get(llm, :model),
        prompt_started_at: DateTime.utc_now(),
        tool_count: 0,
        input_tokens: 0,
        output_tokens: 0,
        steer_count: steer_count_for(plane, prompt)
    }

    persist(%{plane | snapshot: snapshot, prompt_started_mono: monotonic_ms()})
  end

  @doc """
  Folds one canonical event into the snapshot and appends it to the subscriber
  stream.

  Deliberately not persisted here: `boundary/1` writes the snapshot once per
  event, and rewriting it twice per event doubles the IO for nothing.
  """
  @spec observe(t(), map()) :: t()
  def observe(%__MODULE__{packet_dir: nil} = plane, _event), do: plane

  def observe(%__MODULE__{} = plane, event) when is_map(event) do
    Store.append_event(plane.packet_dir, serialisable(event))
    %{plane | snapshot: fold_event(plane.snapshot, event)}
  end

  @doc """
  An event boundary: consume every pending request, then rewrite the snapshot.

  Returns the commands the caller has to act on. Only the caller knows how to
  reach the live renderer, so this decides *what* was asked for and leaves
  *how* to the runner.
  """
  @spec boundary(t()) :: {t(), [command()]}
  def boundary(%__MODULE__{packet_dir: nil} = plane), do: {plane, []}

  def boundary(%__MODULE__{} = plane) do
    {plane, commands} =
      plane.packet_dir
      |> Store.take_requests()
      |> Enum.reduce({plane, []}, fn {name, result}, {acc, commands} ->
        {acc, new_commands} = apply_request(acc, name, result)
        {acc, commands ++ new_commands}
      end)

    {persist(plane), commands}
  end

  @doc """
  Marks the run finished. The snapshot survives the runner, so a reader that
  arrives afterwards sees how it ended rather than a run apparently still in
  flight.
  """
  @spec close(t(), Snapshot.status()) :: t()
  def close(%__MODULE__{packet_dir: nil} = plane, _status), do: plane

  def close(%__MODULE__{} = plane, status) do
    persist(%{plane | snapshot: %{plane.snapshot | status: status}})
  end

  @doc """
  Appends an entry to the control log.
  """
  @spec record(t(), String.t(), map(), keyword()) :: t()
  def record(%__MODULE__{packet_dir: nil} = plane, _command, _params, _opts), do: plane

  def record(%__MODULE__{} = plane, command, params, opts) do
    Store.append_log(plane.packet_dir, %Entry{
      at: DateTime.utc_now(),
      run_id: plane.snapshot.run_id,
      command: command,
      params: params,
      author: Keyword.get(opts, :author),
      outcome: Keyword.get(opts, :outcome, :received),
      reason: Keyword.get(opts, :reason),
      prompt_id: plane.snapshot.prompt_id,
      attempt: plane.snapshot.attempt
    })

    plane
  end

  # -- requests

  defp apply_request(plane, name, {:error, reason}) do
    {reject(plane, "unparseable", %{"file" => name}, nil, inspect(reason)), []}
  end

  defp apply_request(plane, name, {:ok, request}) do
    command = request["command"]
    params = if(is_map(request["params"]), do: request["params"], else: %{})
    author = request["author"]

    cond do
      not is_binary(command) ->
        {reject(plane, "unknown", %{"file" => name}, author, "request has no command"), []}

      request["run_id"] not in [nil, plane.snapshot.run_id] ->
        {reject(plane, command, params, author, "request targets run #{request["run_id"]}"), []}

      true ->
        dispatch(plane, command, params, author)
    end
  end

  defp dispatch(plane, "set_view" = command, params, author) do
    case Snapshot.normalize_view(params) do
      {:ok, updates} when map_size(updates) > 0 ->
        snapshot = %{plane.snapshot | view: Map.merge(plane.snapshot.view, updates)}

        plane =
          %{plane | snapshot: snapshot}
          |> record(command, params, author: author, outcome: :applied)

        {plane, [{:set_view, updates}]}

      {:ok, _empty} ->
        {reject(plane, command, params, author, "no view settings given"), []}

      {:error, reason} ->
        {reject(plane, command, params, author, reason_text(reason)), []}
    end
  end

  # The budget is per prompt and per run. It exists to bound *unattended*
  # provider invocations: on a lane that resumes, a steer is a fresh `codex exec
  # resume`, and a person who steers three times and walks away has created
  # three calls nothing was counting. It is not a limit on how often a human may
  # speak across days, so a new run starts the count again.
  #
  # Exhausting it is a logged refusal, not a run failure. The run carries on
  # unsteered.
  defp dispatch(plane, "steer" = command, params, author) do
    text = params["text"]

    cond do
      not (is_binary(text) and String.trim(text) != "") ->
        {reject(plane, command, params, author, "steer has no text"), []}

      plane.snapshot.prompt_id == nil ->
        {reject(plane, command, params, author, "no prompt is running"), []}

      plane.snapshot.steer_count >= plane.max_steers ->
        {reject(
           plane,
           command,
           params,
           author,
           "steer budget spent (#{plane.snapshot.steer_count}/#{plane.max_steers} for this " <>
             "prompt); raise recovery.max_steers to allow more"
         ), []}

      true ->
        {plane, [{:steer, String.trim(text), author}]}
    end
  end

  defp dispatch(plane, "pause" = command, params, author) do
    if plane.snapshot.prompt_id == nil do
      {reject(plane, command, params, author, "no prompt is running"), []}
    else
      {plane, [{:pause, author}]}
    end
  end

  defp dispatch(plane, command, params, author) do
    {reject(plane, command, params, author, "unknown command"), []}
  end

  @doc """
  Records a steer that was actually delivered, and counts it against the budget.

  Called by the runner rather than by `boundary/1`, because only the runner
  knows whether the text reached the session — a steer refused by the lane must
  not spend budget or leave an artifact claiming the agent was told something.
  """
  @spec steer_delivered(t(), String.t(), String.t() | nil, atom(), atom()) :: t()
  def steer_delivered(%__MODULE__{packet_dir: nil} = plane, _text, _author, _lane, _delivery),
    do: plane

  def steer_delivered(%__MODULE__{} = plane, text, author, lane, delivery) do
    Interventions.append(plane.packet_dir, %{
      at: DateTime.utc_now(),
      prompt_id: plane.snapshot.prompt_id,
      attempt: plane.snapshot.attempt,
      author: author,
      text: text,
      lane: lane,
      delivery: delivery,
      run_id: plane.snapshot.run_id
    })

    plane = %{plane | snapshot: %{plane.snapshot | steer_count: plane.snapshot.steer_count + 1}}

    record(plane, "steer", %{"text" => text, "delivery" => to_string(delivery)},
      author: author,
      outcome: :applied
    )
  end

  @doc """
  Records a steer the lane refused. Costs no budget and leaves no artifact.
  """
  @spec steer_refused(t(), String.t(), String.t() | nil, term()) :: t()
  def steer_refused(%__MODULE__{} = plane, text, author, reason) do
    reject(plane, "steer", %{"text" => text}, author, steer_refusal_text(reason))
  end

  defp steer_refusal_text(:no_live_session),
    do: "no provider session is live; nothing to steer"

  defp steer_refusal_text(:no_active_turn),
    do: "the provider has not started a turn yet; nothing to interrupt"

  defp steer_refusal_text(reason), do: inspect(reason)

  # Carried across attempts of the same prompt and reset when the prompt
  # changes: a retry or a repair is still the same prompt being steered, and
  # handing back a fresh budget on each attempt would make the budget mean
  # nothing.
  defp steer_count_for(%__MODULE__{snapshot: snapshot}, prompt) do
    if snapshot.prompt_id == Map.get(prompt, :num), do: snapshot.steer_count, else: 0
  end

  defp reject(plane, command, params, author, reason) do
    record(plane, command, params, author: author, outcome: :rejected, reason: reason)
  end

  defp reason_text({:unknown_view_key, key}) do
    "unknown view setting #{inspect(key)}; known: " <>
      (Snapshot.view_keys() |> Map.keys() |> Enum.sort() |> Enum.join(", "))
  end

  defp reason_text({:invalid_view_value, key, value}) do
    allowed = Snapshot.view_keys() |> Map.get(key, []) |> Enum.join(", ")
    "#{key} does not take #{inspect(to_string(value))}; allowed: #{allowed}"
  end

  defp reason_text(other), do: inspect(other)

  # -- snapshot maintenance

  defp fold_event(snapshot, %{type: :tool_call_started}),
    do: %{snapshot | tool_count: snapshot.tool_count + 1, event_count: snapshot.event_count + 1}

  defp fold_event(snapshot, %{type: :token_usage_updated, data: data}) when is_map(data) do
    %{
      snapshot
      | input_tokens: max(snapshot.input_tokens, non_neg(data[:input_tokens])),
        output_tokens: max(snapshot.output_tokens, non_neg(data[:output_tokens])),
        event_count: snapshot.event_count + 1
    }
  end

  defp fold_event(snapshot, _event), do: %{snapshot | event_count: snapshot.event_count + 1}

  defp persist(%__MODULE__{} = plane) do
    now_mono = monotonic_ms()

    snapshot = %{
      plane.snapshot
      | updated_at: DateTime.utc_now(),
        elapsed_ms: elapsed(plane.run_started_mono, now_mono),
        prompt_elapsed_ms: elapsed(plane.prompt_started_mono, now_mono)
    }

    Store.write_snapshot(plane.packet_dir, snapshot)
    %{plane | snapshot: snapshot}
  end

  defp elapsed(nil, _now), do: 0
  defp elapsed(started, now), do: max(now - started, 0)

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: 0

  # Events carry atoms, structs, tuples, and pids. JSON carries none of those,
  # and a subscriber stream that drops an event because one field would not
  # encode is worse than one that renders that field as a string.
  defp serialisable(value) when is_struct(value),
    do: value |> Map.from_struct() |> serialisable()

  defp serialisable(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {to_string(key), serialisable(inner)} end)
  end

  defp serialisable(value) when is_list(value), do: Enum.map(value, &serialisable/1)
  defp serialisable(value) when is_tuple(value), do: value |> Tuple.to_list() |> serialisable()

  defp serialisable(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp serialisable(nil), do: nil
  defp serialisable(value) when is_atom(value), do: to_string(value)
  defp serialisable(value), do: inspect(value)

  # Sortable, unique, and readable in a filename. Not a UUID: the first thing
  # anyone does with a run id is grep a log for it.
  defp generate_run_id do
    stamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    "#{stamp}-#{System.unique_integer([:positive, :monotonic])}"
  end
end
