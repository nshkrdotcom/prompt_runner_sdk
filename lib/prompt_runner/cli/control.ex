defmodule PromptRunner.CLI.Control do
  @moduledoc """
  The `prompt_runner control` commands.

  Written **entirely** against `PromptRunner.Control`. Nothing here reaches into
  the runner, the plan, or the control directory directly. That is the point:
  the CLI is one consumer of the control plane, not its owner, and if these
  commands needed anything the module above does not expose then the boundary
  would already have failed.
  """

  alias PromptRunner.Control
  alias PromptRunner.Control.Entry
  alias PromptRunner.Control.Snapshot
  alias PromptRunner.UI

  @follow_interval_ms 500

  @spec status(String.t(), keyword()) :: :ok | {:error, term()}
  def status(packet_dir, opts \\ []) do
    with {:ok, run_ref} <- Control.current_run(packet_dir),
         {:ok, snapshot} <- Control.snapshot(run_ref) do
      if opts[:json] do
        IO.puts(Jason.encode!(Snapshot.to_map(snapshot), pretty: true))
      else
        print_status(snapshot)
      end

      :ok
    end
  end

  @spec view(String.t(), keyword()) :: :ok | {:error, term()}
  def view(packet_dir, opts) do
    settings =
      opts
      |> Keyword.take([:log_mode, :tool_output, :diff])
      |> Map.new()

    if settings == %{} do
      {:error, :no_view_settings}
    else
      with {:ok, run_ref} <- Control.current_run(packet_dir),
           :ok <- Control.set_view(run_ref, settings) do
        {_packet, run_id} = run_ref

        IO.puts(
          UI.green(
            "Requested #{describe(settings)} for run #{run_id}. " <>
              "It applies at the next event boundary; `control log` records the outcome."
          )
        )

        :ok
      end
    end
  end

  @spec steer(String.t(), [String.t()], keyword()) :: :ok | {:error, term()}
  def steer(packet_dir, words, opts \\ []) do
    case Enum.join(words, " ") |> String.trim() do
      "" ->
        {:error, :empty_steer}

      text ->
        with {:ok, run_ref} <- Control.current_run(packet_dir),
             :ok <- Control.steer(run_ref, text, opts) do
          IO.puts(
            UI.green(
              "Steer queued. It is delivered at the next event boundary; " <>
                "`control log` records whether the lane took it."
            )
          )

          :ok
        end
    end
  end

  @spec amend(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def amend(packet_dir, prompt_id, opts) do
    with {:ok, clause, entries} <- amendment_clause(opts),
         :ok <-
           Control.amend(packet_dir, prompt_id,
             clause: clause,
             entries: entries,
             reason: opts[:reason],
             persist: opts[:persist] == true
           ) do
      IO.puts(UI.green("Amended #{prompt_id}: added #{clause} #{inspect(entries)}"))
      IO.puts(UI.dim(persist_note(opts[:persist])))
      :ok
    end
  end

  @spec relax(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def relax(packet_dir, prompt_id, opts) do
    with {:ok, clause} <- relax_clause(opts),
         :ok <-
           Control.relax(packet_dir, prompt_id,
             clause: clause,
             reason: opts[:reason],
             confirm: opts[:confirm] == true,
             persist: opts[:persist] == true
           ) do
      IO.puts(UI.yellow("Relaxed #{prompt_id}: dropped #{clause}"))
      IO.puts(UI.dim(persist_note(opts[:persist])))
      :ok
    end
  end

  @spec contract(String.t(), String.t(), keyword()) :: :ok | {:error, term()}
  def contract(packet_dir, prompt_id, opts \\ []) do
    with {:ok, report} <- Control.contract(packet_dir, prompt_id) do
      if opts[:json] do
        IO.puts(Jason.encode!(report, pretty: true))
      else
        print_contract(report)
      end

      :ok
    end
  end

  defp amendment_clause(opts) do
    cond do
      is_binary(opts[:add_file]) -> {:ok, "files_exist", [opts[:add_file]]}
      is_binary(opts[:add_command]) -> {:ok, "commands", [opts[:add_command]]}
      is_binary(opts[:add_path]) -> {:ok, "changed_paths_only", [opts[:add_path]]}
      true -> {:error, :no_amendment}
    end
  end

  defp relax_clause(opts) do
    if is_binary(opts[:drop]), do: {:ok, opts[:drop]}, else: {:error, :no_relaxation}
  end

  defp persist_note(true),
    do: "Written back to the packet file. Commit it: a packet is a versioned artifact."

  defp persist_note(_persist),
    do: "Run-local. The packet file is unchanged, so a re-run from clean state uses its contract."

  defp print_contract(report) do
    IO.puts("")
    IO.puts(UI.bold("  contract for #{report.prompt_id}"))
    IO.puts("")

    if report.amendments == [] do
      IO.puts("  " <> UI.dim("no amendments; the packet's contract is what is enforced"))
    else
      Enum.each(report.amendments, &print_amendment/1)
      IO.puts("")
    end

    Enum.each(report.diff, &print_diff_line/1)
    IO.puts("")
  end

  defp print_amendment(amendment) do
    marker = phase_marker(amendment["phase"])

    IO.puts(
      "  #{marker}  #{amendment["operation"]} #{amendment["clause"]} " <>
        UI.dim("by #{amendment["author"] || "?"} — #{amendment["reason"]}")
    )
  end

  defp phase_marker("post_failure"), do: UI.red("post_failure")
  defp phase_marker("post_success"), do: UI.yellow("post_success")
  defp phase_marker(_phase), do: UI.green("pre_verify  ")

  defp print_diff_line({:same, clause, entry}), do: IO.puts(UI.dim("    #{clause}: #{entry}"))

  defp print_diff_line({:removed, clause, entry}),
    do: IO.puts(UI.red("  - #{clause}: #{entry}"))

  defp print_diff_line({:added, clause, entry}),
    do: IO.puts(UI.green("  + #{clause}: #{entry}"))

  @spec log(String.t(), keyword()) :: :ok | {:error, term()}
  def log(packet_dir, opts \\ []) do
    with {:ok, run_ref} <- Control.current_run(packet_dir),
         {:ok, entries} <- Control.log(run_ref) do
      Enum.each(entries, &print_entry(&1, opts[:json] == true))

      if opts[:follow] do
        follow(run_ref, length(entries), opts)
      else
        :ok
      end
    end
  end

  @spec watch(String.t(), keyword()) :: :ok | {:error, term()}
  def watch(packet_dir, opts \\ []) do
    with {:ok, run_ref} <- Control.current_run(packet_dir),
         {:ok, ref} <- Control.subscribe(run_ref, self(), from: Keyword.get(opts, :from, :start)) do
      receive_events(ref, opts[:json] == true)
    end
  end

  # -- rendering

  defp print_status(%Snapshot{} = snapshot) do
    IO.puts("")
    IO.puts(UI.bold("  #{snapshot.packet || "(packet)"}  ") <> UI.dim(snapshot.run_id))
    IO.puts("")
    IO.puts("  #{label("status")}#{status_label(snapshot.status)}")

    IO.puts(
      "  #{label("prompt")}#{snapshot.prompt_id || "-"}" <>
        prompt_name_suffix(snapshot.prompt_name)
    )

    IO.puts("  #{label("attempt")}#{snapshot.attempt || "-"} (#{snapshot.mode || "-"})")
    IO.puts("  #{label("provider")}#{snapshot.provider || "-"} / #{snapshot.model || "-"}")

    IO.puts(
      "  #{label("elapsed")}#{duration(snapshot.elapsed_ms)} run, " <>
        "#{duration(snapshot.prompt_elapsed_ms)} this prompt"
    )

    IO.puts("  #{label("tools")}#{snapshot.tool_count}")
    IO.puts("  #{label("tokens")}#{snapshot.input_tokens} in / #{snapshot.output_tokens} out")
    IO.puts("  #{label("events")}#{snapshot.event_count}")

    IO.puts(
      "  #{label("view")}log_mode=#{snapshot.view.log_mode} " <>
        "tool_output=#{snapshot.view.tool_output} diff=#{snapshot.view.diff}"
    )

    IO.puts(
      "  #{label("updated")}#{snapshot.updated_at && DateTime.to_iso8601(snapshot.updated_at)}"
    )

    IO.puts("")
  end

  defp prompt_name_suffix(nil), do: ""
  defp prompt_name_suffix(name), do: " — #{name}"

  defp label(text), do: UI.dim(String.pad_trailing(text, 10))

  defp status_label(:running), do: UI.green("running")
  defp status_label(:completed), do: UI.green("completed")
  defp status_label(:failed), do: UI.red("failed")
  defp status_label(other), do: to_string(other)

  defp duration(ms) when ms < 1000, do: "#{ms}ms"
  defp duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  defp duration(ms) do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    "#{minutes}m#{String.pad_leading(Integer.to_string(seconds), 2, "0")}s"
  end

  defp print_entry(%Entry{} = entry, true), do: IO.puts(Jason.encode!(Entry.to_map(entry)))

  defp print_entry(%Entry{} = entry, false) do
    IO.puts(
      "#{entry.at && DateTime.to_iso8601(entry.at)}  #{outcome_label(entry.outcome)}  " <>
        "#{entry.command} #{inspect(entry.params)} " <>
        UI.dim("by #{entry.author || "?"}#{prompt_suffix(entry)}#{reason_suffix(entry)}")
    )
  end

  defp outcome_label(:applied), do: UI.green("applied ")
  defp outcome_label(:rejected), do: UI.red("rejected")
  defp outcome_label(other), do: String.pad_trailing(to_string(other || "-"), 8)

  defp prompt_suffix(%Entry{prompt_id: nil}), do: ""
  defp prompt_suffix(%Entry{prompt_id: id, attempt: attempt}), do: " on #{id}/#{attempt}"

  defp reason_suffix(%Entry{reason: nil}), do: ""
  defp reason_suffix(%Entry{reason: reason}), do: " — #{reason}"

  defp describe(settings) do
    Enum.map_join(settings, ", ", fn {key, value} -> "#{key}=#{value}" end)
  end

  # -- following

  defp follow(run_ref, seen, opts) do
    Process.sleep(@follow_interval_ms)
    {:ok, entries} = Control.log(run_ref)

    if length(entries) > seen do
      entries |> Enum.drop(seen) |> Enum.each(&print_entry(&1, opts[:json] == true))
      follow(run_ref, length(entries), opts)
    else
      if run_over?(run_ref), do: :ok, else: follow(run_ref, seen, opts)
    end
  end

  defp run_over?(run_ref) do
    case Control.snapshot(run_ref) do
      {:ok, %Snapshot{status: status}} -> status in [:completed, :failed]
      _other -> true
    end
  end

  defp receive_events(ref, json?) do
    receive do
      {:prompt_runner_event, ^ref, event} ->
        print_event(event, json?)
        receive_events(ref, json?)

      {:prompt_runner_control, ^ref, {:run_finished, status}} ->
        IO.puts(UI.dim("-- run #{status} --"))
        :ok
    end
  end

  defp print_event(event, true), do: IO.puts(Jason.encode!(event))

  defp print_event(event, false) do
    IO.puts("#{event["type"]} #{UI.dim(inspect(event["data"]))}")
  end
end
