defmodule PromptRunner do
  @moduledoc """
  Public API for building plans and executing prompt runs.
  """

  alias PromptRunner.Plan
  alias PromptRunner.Run
  alias PromptRunner.Runner
  alias PromptRunner.RunSpec
  alias PromptRunner.Validator

  @spec plan(term(), keyword()) :: {:ok, Plan.t()} | {:error, term()}
  def plan(input, opts \\ []) do
    with {:ok, %RunSpec{} = run_spec} <- RunSpec.build(input, opts),
         {:ok, %Plan{} = plan} <- Plan.build(run_spec) do
      {:ok, plan}
    end
  end

  @spec validate(term(), keyword()) :: :ok | {:error, term()}
  def validate(input, opts \\ []) do
    with {:ok, %Plan{} = plan} <- plan(input, opts) do
      case plan.interface do
        :legacy ->
          Validator.validate_all(plan.config)

        _ ->
          :ok
      end
    end
  end

  @spec run(term(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run(input, opts \\ []) do
    with {:ok, %Plan{} = plan} <- plan(input, opts) do
      Runner.run_plan(plan, opts)
    end
  end

  @spec run_prompt(String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_prompt(prompt_text, opts \\ []) when is_binary(prompt_text) do
    run(prompt_text, opts)
  end

  @spec scaffold(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def scaffold(input, opts \\ []) do
    with {:ok, %Plan{} = plan} <- plan(input, Keyword.put(opts, :interface, :cli)) do
      PromptRunner.Scaffold.write(plan, opts)
    end
  end
end
