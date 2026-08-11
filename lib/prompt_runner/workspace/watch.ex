defmodule PromptRunner.Workspace.Watch do
  @moduledoc "Bounded, evidence-producing workspace health monitor."

  alias PromptRunner.Workspace
  alias PromptRunner.Workspace.{Manifest, Plan}

  @spec run(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(manifest_path, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(manifest_path),
         :ok <- validate_options(opts) do
      plan = Plan.build(manifest)
      started_mono = System.monotonic_time(:millisecond)
      duration_ms = Keyword.fetch!(opts, :duration_seconds) * 1_000
      interval_ms = Keyword.get(opts, :interval_seconds, 600) * 1_000
      evidence_path = evidence_path(plan, started_mono)

      loop(manifest_path, opts, started_mono, duration_ms, interval_ms, evidence_path, [])
    end
  end

  defp loop(manifest_path, opts, started, duration, interval, path, samples) do
    with {:ok, status} <- Workspace.status(manifest_path),
         sample = assess(status, opts),
         :ok <- append_sample(path, sample) do
      emit(sample, opts)
      samples = [sample | samples]
      elapsed = System.monotonic_time(:millisecond) - started

      cond do
        not sample.healthy? ->
          report = final_report(path, samples, elapsed, false, sample.violations)
          {:error, {:workspace_watch_unhealthy, report}}

        elapsed >= duration ->
          {:ok, final_report(path, samples, elapsed, true, [])}

        true ->
          Process.sleep(min(interval, duration - elapsed))
          loop(manifest_path, opts, started, duration, interval, path, samples)
      end
    end
  end

  defp assess(status, opts) do
    progress_limit = Keyword.get(opts, :progress_timeout_seconds, 3_600)
    progress_age = age_seconds(status.last_progress_at)

    violations =
      []
      |> maybe_violation(not status.healthy?, :runtime_unhealthy)
      |> maybe_violation(
        Keyword.get(opts, :require_running, false) and status.state != "running",
        {:not_running, status.state}
      )
      |> maybe_violation(
        Keyword.get(opts, :require_progress, false) and
          (is_nil(progress_age) or progress_age > progress_limit),
        {:progress_stale, progress_age, progress_limit}
      )

    %{
      schema: "prompt_runner.workspace.watch.sample/v1",
      checked_at: status.checked_at,
      workspace: status.workspace,
      run_id: status.run_id,
      state: status.state,
      healthy?: violations == [],
      violations: Enum.reverse(violations),
      last_progress_at: status.last_progress_at,
      progress_age_seconds: progress_age,
      journal_seq: status.journal.last_seq,
      containment: status.containment,
      lease: status.lease
    }
  end

  defp final_report(path, samples, elapsed_ms, passed?, violations) do
    report = %{
      schema: "prompt_runner.workspace.watch.report/v1",
      passed?: passed?,
      elapsed_seconds: div(elapsed_ms, 1_000),
      sample_count: length(samples),
      violations: violations,
      evidence_jsonl: path,
      first_sample: List.last(samples),
      last_sample: List.first(samples),
      completed_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }

    report_path = Path.rootname(path, ".jsonl") <> ".report.json"
    :ok = atomic_write(report_path, Jason.encode!(report, pretty: true))
    Map.put(report, :report_path, report_path)
  end

  defp evidence_path(plan, started_mono) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join([plan.runtime_root, "acceptance", "watch-#{timestamp}-#{started_mono}.jsonl"])
  end

  defp append_sample(path, sample) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, Jason.encode!(sample) <> "\n", [:append, :binary, :sync])
    end
  end

  defp atomic_write(path, contents) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, contents, [:binary, :sync]) do
        File.rename(temp, path)
      end
    after
      _ = File.rm(temp)
    end
  end

  defp validate_options(opts) do
    duration = opts[:duration_seconds]
    interval = Keyword.get(opts, :interval_seconds, 600)

    cond do
      not (is_integer(duration) and duration > 0) -> {:error, {:invalid_watch_duration, duration}}
      not (is_integer(interval) and interval > 0) -> {:error, {:invalid_watch_interval, interval}}
      true -> :ok
    end
  end

  defp age_seconds(nil), do: nil

  defp age_seconds(value) do
    case DateTime.from_iso8601(to_string(value)) do
      {:ok, datetime, _offset} -> max(DateTime.diff(DateTime.utc_now(), datetime), 0)
      _other -> nil
    end
  end

  defp maybe_violation(violations, true, violation), do: [violation | violations]
  defp maybe_violation(violations, false, _violation), do: violations

  defp emit(sample, opts) do
    if Keyword.get(opts, :json, false) do
      IO.puts(Jason.encode!(sample))
    else
      IO.puts(
        "WATCH #{sample.checked_at} workspace=#{sample.workspace} state=#{sample.state} " <>
          "healthy=#{sample.healthy?} seq=#{sample.journal_seq || "?"} " <>
          "progress_age=#{sample.progress_age_seconds || "?"}s"
      )
    end
  end
end
