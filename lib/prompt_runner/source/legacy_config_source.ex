defmodule PromptRunner.Source.LegacyConfigSource do
  @moduledoc """
  Source implementation for explicit v0.4-style PromptRunner config files.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Prompt
  alias PromptRunner.Prompts
  alias PromptRunner.Source.Result

  @impl true
  def load(dir, _opts) when is_binary(dir) do
    if File.dir?(dir) do
      load(Path.join(dir, "runner_config.exs"), [])
    else
      case Config.load(dir) do
        {:ok, config} ->
          {:ok, result_from_config(config)}

        error ->
          error
      end
    end
  end

  @spec result_from_config(Config.t()) :: Result.t()
  def result_from_config(%Config{} = config) do
    %Result{
      prompts: prompts_from_config(config),
      commit_messages: CommitMessages.from_file(config.commit_messages_file),
      target_repos: config.target_repos,
      repo_groups: config.repo_groups,
      source_root: config.config_dir,
      project_dir: config.project_dir,
      phase_names: config.phase_names,
      legacy_config: config
    }
  end

  defp prompts_from_config(config) do
    Enum.map(Prompts.list(config), &hydrate_prompt(&1, config))
  end

  defp hydrate_prompt(%Prompt{} = prompt, config) do
    prompt_path = Path.join(config.config_dir, prompt.file)

    prompt
    |> Map.put(:body, File.read!(prompt_path))
    |> Map.put(:origin, %{type: :file, path: prompt_path})
    |> Map.put(:commit_message, CommitMessages.get_message(config, prompt.num))
    |> Map.put(:validation_commands, [])
    |> Map.put(:metadata, %{})
  end
end
