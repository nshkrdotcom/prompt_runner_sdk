defmodule PromptRunner.SimulatedLLM do
  @moduledoc """
  Built-in deterministic provider used for retry, repair, and resume demos.
  """

  @behaviour PromptRunner.LLM

  @impl true
  def normalize_provider(_value), do: :simulated

  @impl true
  def normalize_sdk(_value), do: :simulated

  @impl true
  def start_stream(llm, _prompt) when is_map(llm) do
    attempt = llm[:attempt] || 1
    step = simulation_attempt(llm, attempt)
    meta = simulation_meta(llm, attempt)
    apply_writes(step, llm)
    {:ok, simulation_stream(step, meta), fn -> :ok end, meta}
  end

  @impl true
  def resume_stream(llm, meta, _prompt) when is_map(llm) and is_map(meta) do
    step = simulation_resume(llm, meta)
    apply_writes(step, llm)
    {:ok, simulation_stream(step, meta), fn -> :ok end, meta}
  end

  defp simulation_attempt(llm, attempt) do
    llm
    |> simulation_config()
    |> Map.get("attempts", [])
    |> Enum.at(max(attempt - 1, 0), %{})
    |> normalize_map()
  end

  defp simulation_resume(llm, meta) do
    llm
    |> simulation_config()
    |> Map.get("resume", %{})
    |> normalize_resume(meta)
  end

  defp simulation_config(llm) do
    llm[:simulation] || llm["simulation"] || %{}
  end

  defp simulation_meta(llm, attempt) do
    provider_session_id = "simulated-#{llm[:prompt_id] || "prompt"}-#{attempt}"

    %{
      sdk: :simulated,
      provider: :simulated,
      model: llm[:model] || "simulated-demo",
      cwd: llm[:cwd],
      provider_session_id: provider_session_id,
      simulation: simulation_config(llm)
    }
  end

  defp simulation_stream(step, meta) do
    [
      %{type: :run_started, data: run_started_data(meta, step)}
      | step_messages(step) ++ [finish_event(step)]
    ]
  end

  defp run_started_data(meta, step) do
    %{
      model: meta.model,
      provider_session_id: meta.provider_session_id,
      metadata: %{"simulated" => true},
      confirmation_source: "simulated"
    }
    |> maybe_put(:simulation_label, step["label"])
  end

  defp step_messages(step) do
    step
    |> Map.get("messages", [])
    |> Enum.map(fn message ->
      %{type: :message_streamed, data: %{delta: to_string(message)}}
    end)
  end

  defp finish_event(%{"error" => error}) when is_map(error) do
    %{
      type: :error_occurred,
      data: %{
        error_message: error["message"] || "simulated failure",
        provider_error: %{
          provider: :simulated,
          kind: normalize_error_kind(error["kind"]),
          message: error["message"] || "simulated failure",
          stderr: error["stderr"],
          truncated?: false
        }
      }
    }
  end

  defp finish_event(_step) do
    %{type: :run_completed, data: %{stop_reason: "end_turn"}}
  end

  defp apply_writes(step, llm) do
    Enum.each(step["writes"] || [], &apply_write(&1, llm))
  end

  defp apply_write(entry, llm) when is_map(entry) do
    path = resolve_write_path(entry, llm)
    File.mkdir_p!(Path.dirname(path))

    content = entry["text"] || ""

    if entry["append"] in [true, "true", "TRUE", 1, "1"] do
      File.write!(path, content, [:append])
    else
      File.write!(path, content)
    end
  end

  defp apply_write(_entry, _llm), do: :ok

  defp resolve_write_path(%{"repo" => repo, "path" => rel_path}, llm)
       when is_binary(repo) and is_binary(rel_path) do
    case get_in(llm, [:repo_paths, repo]) || get_in(llm, ["repo_paths", repo]) do
      root when is_binary(root) -> Path.join(root, rel_path)
      _ -> resolve_relative_path(rel_path, llm[:cwd])
    end
  end

  defp resolve_write_path(%{"path" => rel_path}, llm) when is_binary(rel_path) do
    resolve_relative_path(rel_path, llm[:cwd])
  end

  defp resolve_write_path(_entry, llm), do: resolve_relative_path("simulated.out", llm[:cwd])

  defp resolve_relative_path(path, cwd) do
    if Path.type(path) == :absolute, do: path, else: Path.expand(path, cwd || File.cwd!())
  end

  defp normalize_resume(list, meta) when is_list(list) do
    Enum.at(list, resume_index(meta), %{}) |> normalize_map()
  end

  defp normalize_resume(map, _meta) when is_map(map), do: normalize_map(map)
  defp normalize_resume(_other, _meta), do: %{}

  defp resume_index(meta) do
    meta[:resume_index] || meta["resume_index"] || 0
  end

  defp normalize_map(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), normalize_value(v)} end)

  defp normalize_map(_other), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp normalize_error_kind(kind)
       when kind in [:protocol_error, :transport_error, :transport_exit],
       do: kind

  defp normalize_error_kind(kind) when is_binary(kind) do
    case String.downcase(kind) do
      "protocol_error" -> :protocol_error
      "transport_error" -> :transport_error
      "transport_exit" -> :transport_exit
      _ -> :runtime_error
    end
  end

  defp normalize_error_kind(_kind), do: :runtime_error

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
