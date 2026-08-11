defmodule PromptRunner.Workspace.Status do
  @moduledoc "Read-only reconciliation of run, lease, containment, journal, and progress facts."

  alias ExecutionPlane.Process.Containment.SystemdUser
  alias PromptRunner.Control.Snapshot
  alias PromptRunner.Control.Store
  alias PromptRunner.RunJournal
  alias PromptRunner.RunLock
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
      run_id_agrees? = run_id_agrees?(run, control)
      progress_at = latest_time([run["updated_at"], control && control.updated_at])
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
