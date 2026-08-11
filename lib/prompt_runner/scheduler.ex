defmodule PromptRunner.Scheduler do
  @moduledoc """
  Dependency-aware, deterministic prompt scheduling.

  Independent prompts retain packet order. Dependencies are topologically
  ordered and a failed dependency blocks only its descendants.
  """

  alias PromptRunner.{Plan, Progress}

  @spec validate(Plan.t()) :: :ok | {:error, term()}
  def validate(%Plan{} = plan) do
    known = Enum.map(plan.prompts, & &1.num)

    with :ok <- validate_references(plan.prompts, known),
         {:ok, _ordered} <- order(plan, known) do
      :ok
    end
  end

  @spec order(Plan.t(), [String.t()]) :: {:ok, [String.t()]} | {:error, term()}
  def order(%Plan{} = plan, selected) do
    selected_set = MapSet.new(selected)
    positions = selected |> Enum.with_index() |> Map.new()
    prompt_map = Map.new(plan.prompts, &{&1.num, &1})

    dependencies =
      Map.new(selected, fn id ->
        deps =
          prompt_map
          |> Map.fetch!(id)
          |> Map.get(:depends_on, [])
          |> Enum.filter(&MapSet.member?(selected_set, &1))

        {id, MapSet.new(deps)}
      end)

    topological_order(dependencies, positions, [])
  end

  @spec blocked_dependencies(Plan.t(), String.t(), map()) :: [String.t()]
  def blocked_dependencies(%Plan{} = plan, prompt_id, outcomes) do
    statuses = Progress.statuses(plan)
    prompt = Enum.find(plan.prompts, &(&1.num == prompt_id))

    prompt
    |> Map.get(:depends_on, [])
    |> Enum.reject(fn dependency ->
      outcomes[dependency] == :completed or Progress.completed?(statuses, dependency)
    end)
  end

  defp validate_references(prompts, known) do
    errors =
      Enum.flat_map(prompts, fn prompt ->
        prompt
        |> Map.get(:depends_on, [])
        |> Enum.reject(&(&1 in known))
        |> Enum.map(&%{prompt: prompt.num, unknown_dependency: &1})
      end)

    if errors == [], do: :ok, else: {:error, {:invalid_prompt_dependencies, errors}}
  end

  defp topological_order(dependencies, _positions, ordered) when map_size(dependencies) == 0,
    do: {:ok, Enum.reverse(ordered)}

  defp topological_order(dependencies, positions, ordered) do
    ready =
      dependencies
      |> Enum.filter(fn {_id, deps} -> MapSet.size(deps) == 0 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort_by(&Map.fetch!(positions, &1))

    case ready do
      [] ->
        cycle = dependencies |> Map.keys() |> Enum.sort_by(&Map.fetch!(positions, &1))
        {:error, {:prompt_dependency_cycle, cycle}}

      [next | _rest] ->
        remaining =
          dependencies
          |> Map.delete(next)
          |> Map.new(fn {id, deps} -> {id, MapSet.delete(deps, next)} end)

        topological_order(remaining, positions, [next | ordered])
    end
  end
end
