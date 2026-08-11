defmodule PromptRunner.Control.Snapshot do
  @moduledoc """
  What a run looks like from outside it.

  Everything a dashboard needs for a header, and nothing that requires touching
  the session. A snapshot is read from a file the runner rewrites at event
  boundaries, so reading it cannot disturb, block, or slow the run.
  """

  @type status :: :running | :completed | :failed | :unknown

  @type view :: %{
          log_mode: atom(),
          tool_output: atom(),
          thinking: atom(),
          diff: atom()
        }

  # `run_id` and `packet_dir` are nullable because a snapshot can be built from
  # a file written by an older runner, or one caught mid-write. The struct's
  # own defaults are `nil` and `from_map/1` fills in whatever it finds, so
  # declaring them non-nullable made the type unsatisfiable.
  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          packet_dir: String.t() | nil,
          packet: String.t() | nil,
          status: status(),
          prompt_id: String.t() | nil,
          prompt_name: String.t() | nil,
          attempt: pos_integer() | nil,
          mode: :run | :retry | :repair | nil,
          provider: atom() | nil,
          model: String.t() | nil,
          run_started_at: DateTime.t() | nil,
          prompt_started_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          elapsed_ms: non_neg_integer(),
          prompt_elapsed_ms: non_neg_integer(),
          tool_count: non_neg_integer(),
          input_tokens: non_neg_integer(),
          output_tokens: non_neg_integer(),
          event_count: non_neg_integer(),
          steer_count: non_neg_integer(),
          view: view()
        }

  defstruct run_id: nil,
            packet_dir: nil,
            packet: nil,
            status: :unknown,
            prompt_id: nil,
            prompt_name: nil,
            attempt: nil,
            mode: nil,
            provider: nil,
            model: nil,
            run_started_at: nil,
            prompt_started_at: nil,
            updated_at: nil,
            elapsed_ms: 0,
            prompt_elapsed_ms: 0,
            tool_count: 0,
            input_tokens: 0,
            output_tokens: 0,
            event_count: 0,
            steer_count: 0,
            view: %{log_mode: :compact, tool_output: :summary, thinking: :show, diff: :stat}

  @statuses %{
    "running" => :running,
    "completed" => :completed,
    "failed" => :failed,
    "unknown" => :unknown
  }

  @modes %{"run" => :run, "retry" => :retry, "repair" => :repair}

  @doc """
  Serialises a snapshot to the JSON-ready map written to `snapshot.json`.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = snapshot) do
    %{
      "run_id" => snapshot.run_id,
      "packet_dir" => snapshot.packet_dir,
      "packet" => snapshot.packet,
      "status" => to_string(snapshot.status),
      "prompt_id" => snapshot.prompt_id,
      "prompt_name" => snapshot.prompt_name,
      "attempt" => snapshot.attempt,
      "mode" => snapshot.mode && to_string(snapshot.mode),
      "provider" => snapshot.provider && to_string(snapshot.provider),
      "model" => snapshot.model,
      "run_started_at" => iso(snapshot.run_started_at),
      "prompt_started_at" => iso(snapshot.prompt_started_at),
      "updated_at" => iso(snapshot.updated_at),
      "elapsed_ms" => snapshot.elapsed_ms,
      "prompt_elapsed_ms" => snapshot.prompt_elapsed_ms,
      "tool_count" => snapshot.tool_count,
      "input_tokens" => snapshot.input_tokens,
      "output_tokens" => snapshot.output_tokens,
      "event_count" => snapshot.event_count,
      "steer_count" => snapshot.steer_count,
      "view" => %{
        "log_mode" => to_string(snapshot.view.log_mode),
        "tool_output" => to_string(snapshot.view.tool_output),
        "thinking" => to_string(snapshot.view.thinking),
        "diff" => to_string(snapshot.view.diff)
      }
    }
  end

  @doc """
  Rebuilds a snapshot from the map read back out of `snapshot.json`.

  Every field is optional. A snapshot written by an older runner, or one caught
  mid-write by a reader, yields defaults rather than an exception — a dashboard
  that crashes on a partial header is worse than one showing an empty one.
  """
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      run_id: map["run_id"],
      packet_dir: map["packet_dir"],
      packet: map["packet"],
      status: Map.get(@statuses, map["status"], :unknown),
      prompt_id: map["prompt_id"],
      prompt_name: map["prompt_name"],
      attempt: map["attempt"],
      mode: map["mode"] && Map.get(@modes, map["mode"]),
      provider: provider_atom(map["provider"]),
      model: map["model"],
      run_started_at: parse_datetime(map["run_started_at"]),
      prompt_started_at: parse_datetime(map["prompt_started_at"]),
      updated_at: parse_datetime(map["updated_at"]),
      elapsed_ms: integer(map["elapsed_ms"]),
      prompt_elapsed_ms: integer(map["prompt_elapsed_ms"]),
      tool_count: integer(map["tool_count"]),
      input_tokens: integer(map["input_tokens"]),
      output_tokens: integer(map["output_tokens"]),
      event_count: integer(map["event_count"]),
      steer_count: integer(map["steer_count"]),
      view: view_from_map(map["view"])
    }
  end

  @doc """
  Normalizes view settings from strings or atoms into the settled vocabulary.

  Returns `{:ok, view_updates}` with only the keys the caller actually named,
  or `{:error, {:invalid_view, key, value}}`. An unknown key is an error rather
  than a silent no-op: a dashboard that sets a setting the runner ignores has
  no way to discover that it did nothing.
  """
  @spec normalize_view(map() | keyword()) :: {:ok, map()} | {:error, term()}
  def normalize_view(updates) when is_list(updates),
    do: updates |> Map.new() |> normalize_view()

  def normalize_view(updates) when is_map(updates) do
    Enum.reduce_while(updates, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_view_entry(to_string(key), value) do
        {:ok, normalized_key, normalized_value} ->
          {:cont, {:ok, Map.put(acc, normalized_key, normalized_value)}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @view_values %{
    "log_mode" => %{
      key: :log_mode,
      values: %{
        "compact" => :compact,
        "verbose" => :verbose,
        "studio" => :studio
      }
    },
    "tool_output" => %{
      key: :tool_output,
      values: %{
        "none" => :none,
        "summary" => :summary,
        "preview" => :preview,
        "full" => :full
      }
    },
    "thinking" => %{
      key: :thinking,
      values: %{"show" => :show, "hide" => :hide}
    },
    "diff" => %{
      key: :diff,
      values: %{"none" => :none, "stat" => :stat, "full" => :full}
    }
  }

  @doc """
  The settings `set_view/2` accepts, and the values each one takes.
  """
  @spec view_keys() :: %{optional(String.t()) => [String.t()]}
  def view_keys do
    Map.new(@view_values, fn {key, %{values: values}} ->
      {key, values |> Map.keys() |> Enum.sort()}
    end)
  end

  defp normalize_view_entry(key, value) do
    case Map.fetch(@view_values, key) do
      {:ok, %{key: atom_key, values: values}} ->
        case Map.fetch(values, to_string(value)) do
          {:ok, normalized} -> {:ok, atom_key, normalized}
          :error -> {:error, {:invalid_view_value, key, value}}
        end

      :error ->
        {:error, {:unknown_view_key, key}}
    end
  end

  defp view_from_map(view) when is_map(view) do
    %{
      log_mode: view_atom(view["log_mode"], "log_mode", :compact),
      tool_output: view_atom(view["tool_output"], "tool_output", :summary),
      thinking: view_atom(view["thinking"], "thinking", :show),
      diff: view_atom(view["diff"], "diff", :stat)
    }
  end

  defp view_from_map(_view),
    do: %{log_mode: :compact, tool_output: :summary, thinking: :show, diff: :stat}

  defp view_atom(value, key, default) do
    case Map.fetch(@view_values, key) do
      {:ok, %{values: values}} -> Map.get(values, to_string(value), default)
      :error -> default
    end
  end

  # Bounded conversion: a snapshot file is data, and no field in it may mint an
  # atom. Anything outside the known provider set reads back as a string.
  @providers %{
    "claude" => :claude,
    "codex" => :codex,
    "amp" => :amp,
    "cursor" => :cursor,
    "antigravity" => :antigravity,
    "simulated" => :simulated
  }

  defp provider_atom(value) when is_binary(value), do: Map.get(@providers, value, value)
  defp provider_atom(_value), do: nil

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp iso(nil), do: nil
  defp iso(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _other -> nil
    end
  end

  defp parse_datetime(_value), do: nil
end
