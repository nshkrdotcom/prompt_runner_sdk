defmodule PromptRunner.Workspace.Status do
  @moduledoc """
  Read-only reconciliation of run, lease, containment, journal, and progress facts.

  Agent-controlled runs expose their authenticated nonterminal cursor under
  `agent_control.progress`. Retained progress from an earlier iteration is
  marked `stale`; records from another run or prompt are ignored.
  """

  alias ExecutionPlane.Process.Containment.SystemdUser
  alias PromptRunner.AgentControl
  alias PromptRunner.Control.Snapshot
  alias PromptRunner.Control.Store
  alias PromptRunner.Packet
  alias PromptRunner.RunJournal
  alias PromptRunner.RunLock
  alias PromptRunner.RuntimeStore.FileStore
  alias PromptRunner.Workspace.{Manifest, Plan}

  @spec read(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(manifest_path, opts \\ []) do
    with {:ok, manifest} <- Manifest.load(manifest_path) do
      plan = Plan.build(manifest)
      state_dir = Path.join(plan.runtime_root, "packet")
      current_path = Path.join([state_dir, "runs", "current.json"])
      run = read_json(current_path)
      control = read_control(state_dir)
      containment = containment(manifest.id, opts)
      {lease_state, pid} = RunLock.status(Path.join(state_dir, "run.pid"))
      journal = journal_report(run)
      runtime_state = read_json(Path.join(state_dir, "state.json"))
      progress = progress_report(state_dir, run, control, runtime_state)
      agent_control = agent_control_report(control, runtime_state, run)
      run_id_agrees? = run_id_agrees?(run, control)

      progress_at =
        latest_time([
          run["updated_at"],
          control && control.updated_at,
          agent_control && get_in(agent_control, [:progress, :updated_at])
        ])

      state = run["state"] || "not_started"

      healthy? =
        healthy_state?(state, containment, lease_state) and run_id_agrees? and journal.ready?

      {:ok,
       %{
         schema: "prompt_runner.workspace.status/v1",
         workspace: manifest.id,
         healthy?: healthy?,
         state: state,
         run_id: run["run_id"],
         selection: run["selection"],
         lease: %{state: lease_state, pid: pid},
         containment: containment,
         journal: journal,
         control: control_map(control),
         progress: progress,
         agent_control: agent_control,
         run_id_agrees?: run_id_agrees?,
         last_progress_at: progress_at,
         checked_at: DateTime.utc_now() |> DateTime.to_iso8601()
       }}
    end
  end

  defp containment(id, opts) do
    unit = PromptRunner.Workspace.service_unit(id)

    case SystemdUser.status(unit, opts) do
      {:ok, status} ->
        Map.put(status, :unit, unit)

      {:error, reason} ->
        %{unit: unit, state: :unknown, error: error_value(reason), populated?: nil}
    end
  end

  defp journal_report(%{"snapshot_path" => snapshot_path}) when is_binary(snapshot_path) do
    path = Path.join(Path.dirname(snapshot_path), "journal.jsonl")

    case RunJournal.read(path) do
      {:ok, records} ->
        %{
          ready?: true,
          path: path,
          records: length(records),
          last_seq: last_seq(records),
          error: nil
        }

      {:error, reason} ->
        %{ready?: false, path: path, records: nil, last_seq: nil, error: error_value(reason)}
    end
  end

  defp journal_report(_run),
    do: %{ready?: true, path: nil, records: 0, last_seq: nil, error: nil}

  defp last_seq([]), do: nil
  defp last_seq(records), do: List.last(records)["seq"]

  defp read_control(state_dir) do
    case Store.read_snapshot(Store.state_root(state_dir)) do
      {:ok, snapshot} -> snapshot
      {:error, _reason} -> nil
    end
  end

  defp control_map(nil), do: nil
  defp control_map(snapshot), do: Snapshot.to_map(snapshot)

  defp progress_report(state_dir, run, control, runtime_state) do
    targets = get_in(run, ["selection", "targets"]) |> List.wrap()
    prompt_states = Map.get(runtime_state, "prompts", %{})
    current_id = control && control.prompt_id

    case FileStore.statuses_checked(%{progress_file: Path.join(state_dir, "progress.log")}) do
      {:ok, statuses} ->
        classes = Map.new(targets, &{&1, prompt_class(&1, statuses, prompt_states, control)})

        %{
          selected: length(targets),
          completed: count_class(classes, :completed),
          running: count_class(classes, :running),
          failed: count_class(classes, :failed),
          blocked: count_class(classes, :blocked),
          pending: count_class(classes, :pending),
          current_position: current_position(targets, current_id),
          last_verifier: verifier_status(prompt_states[current_id]),
          reason: progress_reason(targets, prompt_states, current_id),
          error: nil
        }

      {:error, reason} ->
        %{
          selected: length(targets),
          completed: nil,
          running: nil,
          failed: nil,
          blocked: nil,
          pending: nil,
          current_position: current_position(targets, current_id),
          last_verifier: verifier_status(prompt_states[current_id]),
          reason: progress_reason(targets, prompt_states, current_id),
          error: error_value(reason)
        }
    end
  end

  defp prompt_class(id, statuses, prompt_states, control) do
    progress_status = get_in(statuses, [id, :status])
    runtime_status = get_in(prompt_states, [id, "status"])
    current? = control && control.prompt_id == id

    cond do
      current? and control.status == :running ->
        :running

      progress_status == "completed" ->
        :completed

      runtime_status in ["blocked", "agent_control_blocked", "blocked_by_dependency"] ->
        :blocked

      progress_status == "failed" ->
        :failed

      runtime_status in ["failed", "iteration_limit", "finish_rejected"] ->
        :failed

      true ->
        :pending
    end
  end

  defp count_class(classes, class), do: Enum.count(classes, fn {_id, value} -> value == class end)

  defp current_position(targets, current_id) do
    case Enum.find_index(targets, &(&1 == current_id)) do
      nil -> nil
      index -> index + 1
    end
  end

  defp verifier_status(%{"last_verifier" => %{"pass?" => true}}), do: "passed"
  defp verifier_status(%{"last_verifier" => %{"pass?" => false}}), do: "failed"
  defp verifier_status(%{"verifier" => %{"pass?" => true}}), do: "passed"
  defp verifier_status(%{"verifier" => %{"pass?" => false}}), do: "failed"
  defp verifier_status(_prompt_state), do: nil

  defp prompt_reason(%{"reason" => reason}) when is_binary(reason) and reason != "", do: reason
  defp prompt_reason(_prompt_state), do: nil

  defp progress_reason(targets, prompt_states, current_id) do
    prompt_reason(prompt_states[current_id]) ||
      targets
      |> Enum.reverse()
      |> Enum.find_value(fn id -> prompt_reason(prompt_states[id]) end)
  end

  defp agent_control_report(nil, _runtime_state, _run), do: nil

  defp agent_control_report(control, runtime_state, run) do
    prompt_state = get_in(runtime_state, ["prompts", control.prompt_id]) || %{}

    case agent_control_config(control.packet_dir, prompt_state) do
      %{
        enabled?: true,
        max_iterations: max_iterations,
        default_action: default_action
      } ->
        record = Map.get(prompt_state, "agent_control", %{})

        completed_iterations =
          max(integer(prompt_state["iteration"]), integer(record["iteration"]))

        current_iteration =
          if control.status == :running,
            do: completed_iterations + 1,
            else: max(completed_iterations, 1)

        looping? =
          current_iteration > 1 or record["action"] == "repeat" or
            prompt_state["status"] == "agent_control_finish_rejected" or
            default_action == :repeat

        progress = agent_progress(run, control.prompt_id, current_iteration)

        %{
          enabled: true,
          looping: looping?,
          current_iteration: current_iteration,
          completed_iterations: completed_iterations,
          max_iterations: max_iterations,
          last_action: record["action"],
          last_reason: record["reason"],
          progress: progress
        }

      _other ->
        nil
    end
  end

  defp agent_progress(
         %{"run_id" => run_id, "snapshot_path" => snapshot_path},
         prompt_id,
         current_iteration
       )
       when is_binary(run_id) and is_binary(snapshot_path) and is_binary(prompt_id) do
    case AgentControl.latest_progress(Path.dirname(snapshot_path), run_id, prompt_id) do
      %{"iteration" => iteration} = record when iteration <= current_iteration ->
        %{
          run_id: record["run_id"],
          prompt_id: record["prompt_id"],
          iteration: iteration,
          cursor: record["cursor"],
          unit: record["unit"],
          summary: record["summary"],
          updated_at: record["updated_at"],
          stale: iteration != current_iteration
        }

      _other ->
        nil
    end
  end

  defp agent_progress(_run, _prompt_id, _current_iteration), do: nil

  defp agent_control_config(packet_dir, prompt_state) when is_binary(packet_dir) do
    with {:ok, packet} <- Packet.load(packet_dir),
         {:ok, config} <- AgentControl.config(packet.options["agent_control"]) do
      config
    else
      _other -> fallback_agent_control_config(prompt_state)
    end
  end

  defp agent_control_config(_packet_dir, prompt_state),
    do: fallback_agent_control_config(prompt_state)

  defp fallback_agent_control_config(%{"agent_control" => agent_control})
       when is_map(agent_control),
       do: %{enabled?: true, max_iterations: 20, default_action: :continue}

  defp fallback_agent_control_config(_prompt_state),
    do: %{enabled?: false, max_iterations: 20, default_action: :continue}

  defp integer(value) when is_integer(value) and value >= 0, do: value
  defp integer(_value), do: 0

  defp run_id_agrees?(%{"run_id" => run_id}, %{run_id: control_id})
       when is_binary(run_id) and is_binary(control_id),
       do: run_id == control_id

  defp run_id_agrees?(%{"run_id" => run_id}, nil) when is_binary(run_id), do: true
  defp run_id_agrees?(run, _control), do: map_size(run) == 0

  defp healthy_state?("running", %{state: :active, populated?: populated}, :up),
    do: populated in [true, nil]

  defp healthy_state?("completed", %{state: state, populated?: populated}, :down),
    do: state in [:inactive, :failed] and populated in [false, nil]

  defp healthy_state?(_state, _containment, _lease), do: false

  defp read_json(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, value} when is_map(value) <- Jason.decode(contents) do
      value
    else
      _other -> %{}
    end
  end

  defp latest_time(values) do
    values
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn
      %DateTime{} = value -> DateTime.to_iso8601(value)
      value -> to_string(value)
    end)
    |> Enum.max(fn -> nil end)
  end

  defp error_value({kind, exit_code, details})
       when is_atom(kind) and is_integer(exit_code) and is_binary(details) do
    %{kind: Atom.to_string(kind), exit_code: exit_code, details: details}
  end

  defp error_value(reason) when is_binary(reason), do: reason
  defp error_value(reason), do: inspect(reason)
end
