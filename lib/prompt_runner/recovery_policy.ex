defmodule PromptRunner.RecoveryPolicy do
  @moduledoc """
  Recovery decisions for Prompt Runner attempts.
  """

  alias PromptRunner.FailureEnvelope
  alias PromptRunner.Plan
  alias PromptRunner.RecoveryConfig
  alias PromptRunner.Runtime

  @spec config(Plan.t(), map() | nil) :: map()
  def config(%Plan{options: options}, prompt \\ nil) do
    base = RecoveryConfig.from_options(options)

    case prompt_recovery(prompt) do
      override when is_map(override) and map_size(override) > 0 ->
        RecoveryConfig.with_override(base, override)

      _ ->
        base
    end
  end

  @spec resume_allowed?(Plan.t(), map(), :ok | {:error, term()}, non_neg_integer()) :: boolean()
  def resume_allowed?(%Plan{} = plan, prompt, {:error, reason}, resume_count) do
    failure = FailureEnvelope.from_reason(reason)

    failure.resumeable? and
      not failure.local_deterministic? and
      resume_count < RecoveryConfig.resume_attempts(config(plan, prompt))
  end

  def resume_allowed?(_plan, _prompt, _result, _resume_count), do: false

  @spec final_action(Plan.t(), map(), atom(), :ok | {:error, term()}, map()) ::
          {:complete, boolean(), map()}
          | {:provider_failed, term(), map()}
          | {:verification_failed, term(), map()}
          | {:retry, term(), map(), non_neg_integer()}
          | {:repair, map(), term(), map()}
  def final_action(%Plan{} = plan, prompt, mode, stream_result, report) do
    recovery = config(plan, prompt)
    failure = FailureEnvelope.from_result(stream_result)
    attempts = attempt_counts(plan, prompt)

    context = %{
      report: report,
      failure: failure,
      recovery: recovery,
      mode: mode,
      retry_count: attempts.retry,
      repair_count: attempts.repair,
      workspace_changed?: workspace_changed?(plan, prompt, report),
      retry_exhausted?: attempts.retry >= retry_limit(recovery, failure)
    }

    decide_final_action(stream_result, context)
  end

  defp decide_final_action(:ok, %{report: %{pass?: true}, failure: failure}),
    do: {:complete, false, failure}

  defp decide_final_action({:error, reason}, %{report: %{pass?: true} = report, failure: failure}) do
    if verification_override_allowed?(failure, report) do
      {:complete, true, failure}
    else
      provider_failure_result(reason, failure)
    end
  end

  defp decide_final_action(
         :ok,
         %{report: %{pass?: false} = report, failure: failure, recovery: recovery} = context
       ) do
    if repair_after_verification_failure?(recovery, context.repair_count, context.mode) do
      {:repair, report, {:verification_failed, report}, failure}
    else
      {:verification_failed, {:verification_failed, report}, failure}
    end
  end

  defp decide_final_action(
         {:error, reason},
         %{report: report, failure: failure, recovery: recovery} = context
       ) do
    cond do
      retry_candidate?(failure, report, context.retry_count, recovery) ->
        {:retry, reason, failure, retry_delay_ms(recovery, failure, context.retry_count + 1)}

      repair_after_failure?(
        recovery,
        context.repair_count,
        context.mode,
        context.retry_exhausted?,
        context.workspace_changed?
      ) ->
        {:repair, report, reason, failure}

      report.pass? and verification_override_allowed?(failure, report) ->
        {:complete, true, failure}

      true ->
        provider_failure_result(reason, failure)
    end
  end

  defp retry_candidate?(failure, report, retry_count, recovery) do
    verifier_items_present?(report) and failure.retryable? and not failure.local_deterministic? and
      retry_count < retry_limit(recovery, failure)
  end

  defp repair_after_verification_failure?(recovery, repair_count, mode) do
    RecoveryConfig.repair_enabled?(recovery) and
      RecoveryConfig.repair_trigger?(recovery, "trigger_on_nominal_success_with_failed_verifier") and
      repair_count < RecoveryConfig.repair_max_attempts(recovery) and mode != :repair
  end

  defp repair_after_failure?(
         recovery,
         repair_count,
         mode,
         retry_exhausted?,
         workspace_changed?
       ) do
    workspace_changed? and
      RecoveryConfig.repair_enabled?(recovery) and
      repair_count < RecoveryConfig.repair_max_attempts(recovery) and
      mode != :repair and repair_trigger?(recovery, retry_exhausted?)
  end

  defp provider_failure_result(reason, failure), do: {:provider_failed, reason, failure}

  defp retry_limit(recovery, failure) do
    suggested =
      case failure.suggested_max_attempts do
        value when is_integer(value) and value >= 0 -> value
        _ -> nil
      end

    RecoveryConfig.retry_max_attempts(recovery, FailureEnvelope.class_name(failure))
    |> min_if_present(suggested)
  end

  defp min_if_present(value, nil), do: value
  defp min_if_present(left, right), do: min(left, right)

  defp retry_delay_ms(recovery, failure, attempt_index) do
    base = max(RecoveryConfig.retry_base_delay_ms(recovery), 0)
    cap = max(RecoveryConfig.retry_max_delay_ms(recovery), base)
    suggested = failure.suggested_delay_ms || base
    exponential = trunc(:math.pow(2, max(attempt_index - 1, 0)) * suggested)
    delay = min(exponential, cap)

    if RecoveryConfig.retry_jitter?(recovery) and delay > 0 do
      trunc(max(delay * 0.5, 1)) + :rand.uniform(delay - trunc(max(delay * 0.5, 1)) + 1) - 1
    else
      delay
    end
  end

  defp repair_trigger?(recovery, false) do
    RecoveryConfig.repair_trigger?(
      recovery,
      "trigger_on_provider_failure_with_workspace_changes"
    )
  end

  defp repair_trigger?(recovery, true) do
    RecoveryConfig.repair_trigger?(
      recovery,
      "trigger_on_retry_exhaustion_with_workspace_changes"
    )
  end

  defp verification_override_allowed?(failure, report) do
    verifier_items_present?(report) and
      failure.class not in [
        :cli_confirmation_missing,
        :cli_confirmation_mismatch,
        :approval_denied
      ]
  end

  defp verifier_items_present?(report) when is_map(report) do
    items = Map.get(report, :items, Map.get(report, "items", []))
    is_list(items) and items != []
  end

  defp attempt_counts(plan, prompt) do
    {:ok, attempts} = Runtime.get_attempts(plan, prompt.num)

    %{
      retry: Enum.count(attempts, &(&1["mode"] == "retry")),
      repair: Enum.count(attempts, &(&1["mode"] == "repair"))
    }
  end

  defp workspace_changed?(plan, prompt, report) do
    git_changed?(plan, prompt) or verifier_changed?(report)
  end

  defp git_changed?(plan, prompt) do
    Enum.any?(repo_roots(plan, prompt), &repo_changed?/1)
  end

  defp verifier_changed?(report) when is_map(report) do
    Enum.any?(Map.get(report, :items, Map.get(report, "items", [])), &item_indicates_change?/1)
  end

  defp verifier_changed?(_report), do: false

  defp item_indicates_change?(item) when is_map(item) do
    kind = map_get(item, :kind)
    resolved_path = map_get(item, :resolved_path)
    changed_paths = map_get(item, :changed_paths) || []

    (is_binary(resolved_path) and File.exists?(resolved_path) and
       kind in ["file_exists", "contains", "matches"]) or
      (is_list(changed_paths) and changed_paths != [])
  end

  defp item_indicates_change?(_item), do: false

  defp repo_roots(%Plan{config: config}, %{target_repos: repos})
       when is_list(repos) and repos != [] do
    repos
    |> Enum.map(fn repo_name ->
      case Enum.find(config.target_repos || [], &(&1.name == repo_name)) do
        %{path: path} -> path
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp repo_roots(%Plan{config: config}, _prompt) do
    case config.target_repos do
      repos when is_list(repos) and repos != [] ->
        repos
        |> Enum.filter(& &1.default)
        |> Enum.map(& &1.path)

      _ ->
        [config.project_dir]
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp repo_changed?(root) when is_binary(root) do
    git_dir = Path.join(root, ".git")

    if File.dir?(git_dir) do
      git_status_changed?(root)
    else
      false
    end
  end

  defp repo_changed?(_root), do: false

  defp git_status_changed?(root) do
    case System.cmd("git", ["status", "--porcelain"], cd: root, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output) != ""
      _ -> false
    end
  end

  defp prompt_recovery(%{metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "recovery") || Map.get(metadata, :recovery)
  end

  defp prompt_recovery(_prompt), do: nil
end
