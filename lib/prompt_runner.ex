defmodule PromptRunner do
  @moduledoc """
  Public API for building plans and executing prompt runs.
  """

  alias PromptRunner.Plan
  alias PromptRunner.Run
  alias PromptRunner.Runner
  alias PromptRunner.RunSpec
  alias PromptRunner.Runtime
  alias PromptRunner.Validator

  # Baked in at compile time from mix.exs so generated packets, scaffolds, and
  # CLI output cannot drift from the released version.
  @version Mix.Project.config()[:version]

  @doc """
  Returns the Prompt Runner version.

  This is the single source of truth for every version string Prompt Runner
  emits, including the CLI banner, generated packet manifests, and the
  `run_prompts.exs` install entry.
  """
  @spec version() :: String.t()
  def version, do: @version

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

  @spec preflight(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def preflight(input, opts \\ []) do
    with {:ok, %Plan{} = plan} <- plan(input, opts) do
      Runner.preflight_plan(plan, opts)
    end
  end

  @doc """
  Builds a plan from `input` and runs it.

  ## Selecting what runs

  Exactly one of these decides the targets; the first that applies wins.

  - `prompts: ["02", "03"]` — run exactly these, in this order. An id naming no
    prompt is an error rather than a shorter run.
  - `phase: 2` — run one phase
  - `remaining: true` — run every prompt whose recorded status is not
    `completed`, in order, including prompts *earlier* than the furthest one
    that finished. A prompt with no record is remaining. A missing progress
    store means a new run; an existing unreadable or malformed store is an
    error rather than permission to re-run the packet.
  - `continue: true` — resume from `last_completed + 1`. This steps over an
    earlier prompt that failed or never ran; when it does, the skipped prompts
    are named.
  - `all: true` — run everything

  ## Pre-flight verification

  `verify_first: true` evaluates a prompt's verify contract before invoking the
  provider and, if it already passes, marks the prompt completed with no
  session and records that no session ran. It defaults on under
  `remaining: true` and off for explicitly named prompts, since naming a prompt
  is a request to run it. A contract with no evaluable clause, and one
  containing `changed_paths_only`, are never pre-flighted — both would pass
  vacuously.

  `keep_going: true` records prompt-local errors, attempts the rest of the
  selected prompts, and returns all failures at the end. The default remains
  fail-fast for dependent prompt chains.
  """
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

  @spec repair(term(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def repair(input, opts \\ []) do
    prompt_id = Keyword.get(opts, :prompt) || Keyword.get(opts, :id)

    with true <- is_binary(prompt_id) || {:error, :missing_prompt_id},
         {:ok, %Plan{} = plan} <- plan(input, opts) do
      Runner.repair_plan(plan, prompt_id, opts)
    end
  end

  @spec status(term()) :: {:ok, map()} | {:error, term()}
  def status(input) do
    {:ok, Runtime.get_status(input) |> elem(1)}
  end

  @spec scaffold(term(), keyword()) :: {:ok, map()} | {:error, term()}
  def scaffold(input, opts \\ []) do
    with {:ok, %Plan{} = plan} <- plan(input, Keyword.put(opts, :interface, :cli)) do
      PromptRunner.Scaffold.write(plan, opts)
    end
  end
end
