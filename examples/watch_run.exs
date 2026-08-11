# The Phase B boundary test: a consumer that is not the CLI, driving a live run
# through `PromptRunner.Control` alone.
#
#   mix run examples/watch_run.exs PACKET_DIR [--tool-output full]
#
# It prints the run's header, follows its events to the end, and optionally
# changes how the run renders while it is running. If this file ever needs
# anything outside `PromptRunner.Control`, the boundary has failed and a
# Phoenix LiveView could not be written against it either.

alias PromptRunner.Control

{opts, argv, _} = OptionParser.parse(System.argv(), switches: [tool_output: :string])
packet_dir = List.first(argv) || File.cwd!()

{:ok, run_ref} = Control.current_run(packet_dir)
{:ok, snapshot} = Control.snapshot(run_ref)

IO.puts("packet   #{snapshot.packet} (#{snapshot.run_id})")
IO.puts("status   #{snapshot.status}")
IO.puts("prompt   #{snapshot.prompt_id} attempt #{snapshot.attempt} (#{snapshot.mode})")
IO.puts("provider #{snapshot.provider} / #{snapshot.model}")
IO.puts("elapsed  #{snapshot.elapsed_ms}ms")
IO.puts("tokens   #{snapshot.input_tokens} in / #{snapshot.output_tokens} out")
IO.puts("view     #{inspect(snapshot.view)}")
IO.puts("")

if tool_output = opts[:tool_output] do
  case Control.set_view(run_ref, %{tool_output: tool_output}, author: "watch_run.exs") do
    :ok -> IO.puts("requested tool_output=#{tool_output}\n")
    {:error, reason} -> IO.puts("refused: #{inspect(reason)}\n")
  end
end

{:ok, ref} = Control.subscribe(run_ref, self())

defmodule Watch do
  def loop(ref, count) do
    receive do
      {:prompt_runner_event, ^ref, event} ->
        IO.puts("#{String.pad_trailing(event["type"], 22)} #{summarize(event["data"])}")
        loop(ref, count + 1)

      {:prompt_runner_control, ^ref, {:run_finished, status}} ->
        IO.puts("\nrun #{status} after #{count} events")
    after
      120_000 -> IO.puts("\nno events for 120s; giving up after #{count}")
    end
  end

  defp summarize(data) when is_map(data) do
    data
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{truncate(value)}" end)
  end

  defp summarize(_data), do: ""

  defp truncate(value) when is_binary(value) do
    value |> String.replace("\n", "\\n") |> String.slice(0, 40)
  end

  defp truncate(value), do: value |> inspect() |> String.slice(0, 40)
end

Watch.loop(ref, 0)

{:ok, entries} = Control.log(run_ref)

unless entries == [] do
  IO.puts("\ncontrol log:")

  Enum.each(
    entries,
    &IO.puts("  #{&1.outcome} #{&1.command} #{inspect(&1.params)} by #{&1.author}")
  )
end
