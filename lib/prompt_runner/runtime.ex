defmodule PromptRunner.Runtime do
  @moduledoc """
  Packet-local runtime state persisted under `.prompt_runner/state.json`.
  """

  alias PromptRunner.Paths
  alias PromptRunner.Plan

  @type state :: map()

  @spec get_status(String.t() | Plan.t()) :: {:ok, state()}
  def get_status(source) do
    {:ok, read_state(state_path(source))}
  end

  @spec get_attempts(String.t() | Plan.t(), String.t()) :: {:ok, [map()]}
  def get_attempts(source, prompt_id) do
    {:ok,
     source
     |> read_prompt_state(prompt_id)
     |> Map.get("attempts", [])}
  end

  @spec get_failures(String.t() | Plan.t(), String.t()) :: {:ok, [map()]}
  def get_failures(source, prompt_id) do
    {:ok,
     source
     |> read_prompt_state(prompt_id)
     |> Map.get("attempts", [])
     |> Enum.filter(&(&1["status"] in ["failed", "verification_failed", "retry_scheduled"]))}
  end

  @spec prompt_state(String.t() | Plan.t(), String.t()) :: {:ok, map()}
  def prompt_state(source, prompt_id) do
    {:ok, read_prompt_state(source, prompt_id)}
  end

  @spec record_attempt_started(String.t() | Plan.t(), map(), integer(), String.t()) :: :ok
  def record_attempt_started(source, prompt, attempt, mode) do
    update_prompt_state(source, prompt.num, fn prompt_state ->
      attempts = Map.get(prompt_state, "attempts", [])

      entry = %{
        "attempt" => attempt,
        "mode" => mode,
        "started_at" => timestamp(),
        "status" => "running",
        "prompt_name" => prompt.name
      }

      prompt_state
      |> Map.put("status", "running")
      |> Map.put("last_attempt", attempt)
      |> Map.put("attempts", attempts ++ [entry])
    end)
  end

  @spec record_attempt_result(String.t() | Plan.t(), String.t(), integer(), map()) :: :ok
  def record_attempt_result(source, prompt_id, attempt, attrs) when is_map(attrs) do
    update_prompt_state(source, prompt_id, fn prompt_state ->
      attempts =
        prompt_state
        |> Map.get("attempts", [])
        |> Enum.map(&merge_attempt_result(&1, attempt, attrs))

      prompt_state
      |> Map.merge(stringify_keys(Map.drop(attrs, ["attempt"])))
      |> Map.put("attempts", attempts)
    end)
  end

  @spec mark_status(String.t() | Plan.t(), String.t(), String.t(), map()) :: :ok
  def mark_status(source, prompt_id, status, attrs \\ %{}) do
    update_prompt_state(source, prompt_id, fn prompt_state ->
      prompt_state
      |> Map.put("status", status)
      |> Map.merge(stringify_keys(attrs))
      |> Map.put("updated_at", timestamp())
    end)
  end

  @spec state_path(String.t() | Plan.t()) :: String.t()
  def state_path(%Plan{state_dir: state_dir, source_root: source_root}) do
    Paths.resolve(state_dir || Path.join(source_root, ".prompt_runner"))
    |> Path.join("state.json")
  end

  def state_path(source) when is_binary(source) do
    Paths.resolve(source)
    |> Path.join(".prompt_runner")
    |> Path.join("state.json")
  end

  defp read_prompt_state(source, prompt_id) do
    read_state(state_path(source))
    |> Map.get("prompts", %{})
    |> Map.get(prompt_id, %{})
  end

  defp merge_attempt_result(entry, attempt, attrs) do
    if entry["attempt"] == attempt do
      entry
      |> Map.merge(stringify_keys(attrs))
      |> Map.put("completed_at", timestamp())
    else
      entry
    end
  end

  defp update_prompt_state(source, prompt_id, fun) do
    path = state_path(source)
    File.mkdir_p!(Path.dirname(path))

    state = read_state(path)
    prompts = Map.get(state, "prompts", %{})
    prompt_state = Map.get(prompts, prompt_id, %{})
    updated_prompt_state = fun.(prompt_state)
    updated_prompts = Map.put(prompts, prompt_id, updated_prompt_state)

    updated_state =
      state
      |> Map.put("prompts", updated_prompts)
      |> Map.put("updated_at", timestamp())

    File.write!(path, Jason.encode!(updated_state, pretty: true))
  end

  defp read_state(path) do
    case File.read(path) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> default_state(path)
        end

      {:error, _reason} ->
        default_state(path)
    end
  end

  defp default_state(path) do
    %{
      "version" => 1,
      "state_path" => path,
      "prompts" => %{},
      "updated_at" => timestamp()
    }
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value({repo, {:ok, value}}) when is_binary(repo) do
    %{"repo" => repo, "status" => "ok", "value" => normalize_value(value)}
  end

  defp normalize_value({repo, {:skip, reason}}) when is_binary(repo) do
    %{"repo" => repo, "status" => "skip", "reason" => normalize_value(reason)}
  end

  defp normalize_value({repo, {:error, reason}}) when is_binary(repo) do
    %{"repo" => repo, "status" => "error", "reason" => normalize_value(reason)}
  end

  defp normalize_value({:ok, value}) do
    %{"status" => "ok", "value" => normalize_value(value)}
  end

  defp normalize_value({:skip, reason}) do
    %{"status" => "skip", "reason" => normalize_value(reason)}
  end

  defp normalize_value({:error, reason}) do
    %{"status" => "error", "reason" => normalize_value(reason)}
  end

  defp normalize_value(value) when is_tuple(value) do
    %{"tuple" => value |> Tuple.to_list() |> Enum.map(&normalize_value/1)}
  end

  defp normalize_value(%_{} = value) do
    value
    |> Map.from_struct()
    |> stringify_keys()
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp timestamp, do: DateTime.utc_now() |> DateTime.to_iso8601()
end
