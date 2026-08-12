defmodule PromptRunner.CLI.Status do
  @moduledoc false

  alias PromptRunner.UI

  @spec print_workspace(map(), keyword()) :: :ok
  def print_workspace(status, opts \\ []) do
    IO.write(render_workspace(status, opts))
    :ok
  end

  @spec render_workspace(map(), keyword()) :: String.t()
  def render_workspace(status, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    color? = Keyword.get(opts, :color, true)
    control = status[:control] || %{}
    progress = status[:progress] || %{}
    agent_control = status[:agent_control]

    [
      "",
      header(status, color?),
      progress_line(progress, agent_control, color?),
      current_line(status[:state], control, progress, color?),
      iteration_line(agent_control, color?),
      reason_line(agent_control, progress, color?),
      attempt_line(control, color?),
      provider_line(control, color?),
      activity_line(control, status[:last_progress_at], now, color?),
      token_line(control, color?),
      verifier_line(progress, color?),
      service_line(status, color?),
      ""
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp header(status, color?) do
    state = status[:state] || "unknown"
    health = health_label(state, status[:healthy?])

    text =
      "  #{status[:workspace] || "workspace"} — #{String.upcase(to_string(state))} · #{health}"

    decorate(text, state_color(state), color?, :bold)
  end

  defp progress_line(%{error: error}, _agent_control, color?) when not is_nil(error),
    do: line("progress", "unavailable", color?)

  defp progress_line(%{selected: selected} = progress, _agent_control, color?)
       when is_integer(selected) and selected > 1 do
    details =
      [
        "#{progress[:completed]}/#{selected} prompts complete",
        count_phrase(progress[:running], "running"),
        count_phrase(progress[:failed], "failed"),
        count_phrase(progress[:blocked], "blocked"),
        count_phrase(progress[:pending], "pending")
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    line("progress", details, color?)
  end

  defp progress_line(_progress, _agent_control, _color?), do: nil

  defp current_line(state, control, progress, color?) do
    id = control["prompt_id"]

    if is_binary(id) do
      suffix = if is_binary(control["prompt_name"]), do: " — #{control["prompt_name"]}", else: ""

      sequence =
        if is_integer(progress[:current_position]) and is_integer(progress[:selected]) and
             progress[:selected] > 1,
           do: " · #{progress[:current_position]} of #{progress[:selected]}",
           else: ""

      line(prompt_label(state), id <> suffix <> sequence, color?)
    end
  end

  defp iteration_line(%{looping: true} = report, color?) do
    verified = report[:completed_iterations] || 0

    details =
      "#{report[:current_iteration]} of #{report[:max_iterations]} · " <>
        "#{verified} verified" <>
        if(is_binary(report[:last_action]),
          do: " · last action #{report[:last_action]}",
          else: ""
        )

    line("iteration", details, color?)
  end

  defp iteration_line(_agent_control, _color?), do: nil

  defp reason_line(%{looping: true, last_reason: reason}, _progress, color?)
       when is_binary(reason) and reason != "",
       do: wrapped_line("reason", reason, color?)

  defp reason_line(_agent_control, %{reason: reason}, color?)
       when is_binary(reason) and reason != "",
       do: wrapped_line("reason", reason, color?)

  defp reason_line(_agent_control, _progress, _color?), do: nil

  defp attempt_line(control, color?) do
    attempt = control["attempt"]
    mode = control["mode"] || "run"

    if (is_integer(attempt) and attempt > 1) or mode in ["retry", "repair"] do
      line("attempt", "#{mode} #{attempt || "-"}", color?)
    end
  end

  defp provider_line(control, color?) do
    if control["provider"] || control["model"] do
      line("provider", "#{control["provider"] || "-"} / #{control["model"] || "-"}", color?)
    end
  end

  defp activity_line(control, last_progress_at, now, color?) do
    parts =
      [
        duration_phrase(control["prompt_elapsed_ms"], "this prompt"),
        age_phrase(last_progress_at || control["updated_at"], now),
        positive_count(control["tool_count"], "tools"),
        positive_count(control["event_count"], "events")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: nil, else: line("activity", Enum.join(parts, " · "), color?)
  end

  defp token_line(control, color?) do
    input = control["input_tokens"] || 0
    output = control["output_tokens"] || 0

    if input > 0 or output > 0, do: line("tokens", "#{input} in / #{output} out", color?)
  end

  defp verifier_line(%{last_verifier: result}, color?) when result in ["passed", "failed"],
    do: line("last check", result, color?)

  defp verifier_line(_progress, _color?), do: nil

  defp service_line(status, color?) do
    containment = status[:containment] || %{}
    lease = status[:lease] || %{}
    state = containment[:state] || containment["state"] || "unknown"
    process = lease[:state] || lease["state"] || "unknown"
    line("service", "#{state} · process #{process}", color?)
  end

  defp line(label, value, color?) do
    rendered_label = String.pad_trailing(label, 11)
    "  #{decorate(rendered_label, :dim, color?)}#{value}"
  end

  defp wrapped_line(label, value, color?) do
    width = 88
    indent = String.duplicate(" ", 13)

    value
    |> String.split()
    |> Enum.reduce([], fn word, lines ->
      case lines do
        [] ->
          [word]

        [current | rest] when byte_size(current) + byte_size(word) + 1 <= width ->
          [current <> " " <> word | rest]

        _other ->
          [word | lines]
      end
    end)
    |> Enum.reverse()
    |> case do
      [] ->
        nil

      [first | rest] ->
        Enum.join([line(label, first, color?) | Enum.map(rest, &(indent <> &1))], "\n")
    end
  end

  defp decorate(text, color, color?, weight \\ nil)
  defp decorate(text, _color, false, _weight), do: text
  defp decorate(text, color, true, :bold), do: text |> UI.bold() |> decorate(color, true)
  defp decorate(text, :green, true, _weight), do: UI.green(text)
  defp decorate(text, :red, true, _weight), do: UI.red(text)
  defp decorate(text, :yellow, true, _weight), do: UI.yellow(text)
  defp decorate(text, :dim, true, _weight), do: UI.dim(text)
  defp decorate(text, _color, true, _weight), do: text

  defp state_color("running"), do: :green
  defp state_color("completed"), do: :green
  defp state_color("failed"), do: :red
  defp state_color("blocked"), do: :red
  defp state_color(_state), do: :yellow

  defp health_label("not_started", _healthy?), do: "not started"
  defp health_label("stopped", _healthy?), do: "stopped"
  defp health_label(_state, true), do: "healthy"
  defp health_label(_state, _healthy?), do: "needs attention"

  defp prompt_label("running"), do: "current"
  defp prompt_label("failed"), do: "stopped at"
  defp prompt_label("blocked"), do: "stopped at"
  defp prompt_label("completed"), do: "last prompt"
  defp prompt_label(_state), do: "prompt"

  defp count_phrase(value, label) when is_integer(value) and value > 0, do: "#{value} #{label}"
  defp count_phrase(_value, _label), do: nil

  defp positive_count(value, label) when is_integer(value) and value > 0,
    do: "#{value} #{label}"

  defp positive_count(_value, _label), do: nil

  defp duration_phrase(ms, suffix) when is_integer(ms) and ms >= 0,
    do: "#{duration(ms)} #{suffix}"

  defp duration_phrase(_ms, _suffix), do: nil

  defp duration(ms) when ms < 1000, do: "#{ms}ms"
  defp duration(ms) when ms < 60_000, do: "#{Float.round(ms / 1000, 1)}s"

  defp duration(ms) do
    hours = div(ms, 3_600_000)
    minutes = div(rem(ms, 3_600_000), 60_000)
    seconds = div(rem(ms, 60_000), 1000)

    if hours > 0,
      do: "#{hours}h#{String.pad_leading(Integer.to_string(minutes), 2, "0")}m",
      else: "#{minutes}m#{String.pad_leading(Integer.to_string(seconds), 2, "0")}s"
  end

  defp age_phrase(value, now) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} ->
        seconds = max(DateTime.diff(now, datetime, :second), 0)
        "updated #{age(seconds)} ago"

      _other ->
        nil
    end
  end

  defp age_phrase(_value, _now), do: nil

  defp age(seconds) when seconds < 60, do: "#{seconds}s"
  defp age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m"
  defp age(seconds), do: "#{div(seconds, 3600)}h#{div(rem(seconds, 3600), 60)}m"
end
