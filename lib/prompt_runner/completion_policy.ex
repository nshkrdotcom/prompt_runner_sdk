defmodule PromptRunner.CompletionPolicy do
  @moduledoc """
  Resolves packet-level completion ownership.

  Verifier-owned completion is the backward-compatible default. Agent-owned
  completion keeps executable quality control inside the provider session and
  asks Prompt Runner to evaluate structural evidence only.
  """

  alias PromptRunner.Plan
  alias PromptRunner.Verifier

  @default %{completion: :verifier_owned, incomplete: :fail}
  @structural_keys Verifier.contract_keys() -- ~w(commands changed_paths_only repos_clean)

  @type t :: %{
          completion: :verifier_owned | :agent_owned,
          incomplete: :fail | :repeat
        }

  @spec from_options(map()) :: {:ok, t()} | {:error, term()}
  def from_options(options) when is_map(options) do
    options
    |> field(:execution)
    |> normalize()
  end

  @spec from_plan(Plan.t()) :: t()
  def from_plan(%Plan{options: options}) do
    case from_options(options) do
      {:ok, policy} -> policy
      {:error, reason} -> raise ArgumentError, "invalid completion policy: #{inspect(reason)}"
    end
  end

  @spec normalize(term()) :: {:ok, t()} | {:error, term()}
  def normalize(nil), do: {:ok, @default}
  def normalize(%{} = execution) when map_size(execution) == 0, do: {:ok, @default}

  def normalize(execution) when is_map(execution) do
    unknown =
      execution
      |> Map.keys()
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 in ~w(completion incomplete)))

    if unknown == [] do
      normalize_values(field(execution, :completion), field(execution, :incomplete))
    else
      {:error, {:unknown_execution_keys, Enum.sort(unknown)}}
    end
  end

  def normalize(other), do: {:error, {:invalid_execution, other}}

  @spec validate_prompts(t(), [map()]) :: :ok | {:error, term()}
  def validate_prompts(%{completion: :verifier_owned}, _prompts), do: :ok

  def validate_prompts(%{completion: :agent_owned}, prompts) when is_list(prompts) do
    findings = Enum.flat_map(prompts, &prompt_findings/1)
    if findings == [], do: :ok, else: {:error, {:invalid_agent_owned_prompts, findings}}
  end

  @spec agent_owned?(Plan.t() | t()) :: boolean()
  def agent_owned?(%Plan{} = plan), do: from_plan(plan).completion == :agent_owned
  def agent_owned?(%{completion: completion}), do: completion == :agent_owned

  @spec structural_contract?(map()) :: boolean()
  def structural_contract?(contract) when is_map(contract) do
    Enum.any?(@structural_keys, &(entries(contract, &1) != []))
  end

  @spec command_contract?(map(), [term()]) :: boolean()
  def command_contract?(contract, validation_commands \\ []) when is_map(contract) do
    entries(contract, "commands") != [] or List.wrap(validation_commands) != []
  end

  defp normalize_values(nil, nil), do: {:ok, @default}

  defp normalize_values(completion, incomplete) do
    completion = normalize_value(completion)
    incomplete = normalize_value(incomplete)

    case {completion, incomplete} do
      {:verifier_owned, nil} ->
        {:ok, @default}

      {:verifier_owned, :fail} ->
        {:ok, @default}

      {:agent_owned, :repeat} ->
        {:ok, %{completion: :agent_owned, incomplete: :repeat}}

      {:agent_owned, nil} ->
        {:error, {:agent_owned_requires, %{incomplete: :repeat}}}

      {value, _} when value not in [:verifier_owned, :agent_owned] ->
        {:error, {:invalid_completion, completion}}

      {:verifier_owned, value} ->
        {:error, {:invalid_incomplete_policy, :verifier_owned, value}}

      {:agent_owned, value} ->
        {:error, {:invalid_incomplete_policy, :agent_owned, value}}
    end
  end

  defp normalize_value(nil), do: nil
  defp normalize_value(:verifier_owned), do: :verifier_owned
  defp normalize_value(:agent_owned), do: :agent_owned
  defp normalize_value(:fail), do: :fail
  defp normalize_value(:repeat), do: :repeat
  defp normalize_value("verifier_owned"), do: :verifier_owned
  defp normalize_value("agent_owned"), do: :agent_owned
  defp normalize_value("fail"), do: :fail
  defp normalize_value("repeat"), do: :repeat
  defp normalize_value(value), do: value

  defp prompt_findings(prompt) do
    contract = prompt.verify || %{}

    []
    |> maybe_add(
      command_contract?(contract, prompt.validation_commands),
      %{prompt_id: prompt.num, kind: :verify_commands_not_allowed}
    )
    |> maybe_add(
      not structural_contract?(contract),
      %{prompt_id: prompt.num, kind: :prompt_specific_structural_evidence_required}
    )
  end

  defp maybe_add(findings, true, finding), do: findings ++ [finding]
  defp maybe_add(findings, false, _finding), do: findings

  defp entries(contract, key) do
    contract
    |> field(key)
    |> List.wrap()
    |> Enum.reject(&is_nil/1)
  end

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key))
  end

  defp field(_map, _key), do: nil
end
