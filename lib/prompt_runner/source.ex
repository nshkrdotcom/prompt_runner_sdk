defmodule PromptRunner.Source do
  @moduledoc """
  Behaviour for loading prompts from directories, legacy config, or in-memory input.
  """

  alias PromptRunner.Prompt

  @callback load(source :: term(), opts :: keyword()) ::
              {:ok, PromptRunner.Source.Result.t()} | {:error, term()}

  defmodule Result do
    @moduledoc """
    Normalized source output consumed by `PromptRunner.Plan`.
    """

    @type t :: %__MODULE__{
            prompts: [Prompt.t()],
            commit_messages: %{optional({String.t(), String.t() | nil}) => String.t()},
            target_repos: [map()] | nil,
            repo_groups: map(),
            source_root: String.t() | nil,
            project_dir: String.t() | nil,
            phase_names: map(),
            metadata: map(),
            legacy_config: PromptRunner.Config.t() | nil
          }

    defstruct prompts: [],
              commit_messages: %{},
              target_repos: nil,
              repo_groups: %{},
              source_root: nil,
              project_dir: nil,
              phase_names: %{},
              metadata: %{},
              legacy_config: nil
  end
end
