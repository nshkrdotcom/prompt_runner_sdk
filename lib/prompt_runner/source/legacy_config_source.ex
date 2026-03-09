defmodule PromptRunner.Source.LegacyConfigSource do
  @moduledoc """
  Source implementation for explicit v0.4-style PromptRunner config files.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Prompts
  alias PromptRunner.Source.Result

  @impl true
  def load(dir, _opts) when is_binary(dir) do
    if File.dir?(dir) do
      load(Path.join(dir, "runner_config.exs"), [])
    else
      with {:ok, config} <- Config.load(dir) do
        prompts =
          config
          |> Prompts.list()
          |> Enum.map(fn prompt ->
            prompt_path = Path.join(config.config_dir, prompt.file)

            prompt
            |> Map.put(:body, File.read!(prompt_path))
            |> Map.put(:origin, %{type: :file, path: prompt_path})
            |> Map.put(:commit_message, CommitMessages.get_message(config, prompt.num))
            |> Map.put(:validation_commands, [])
            |> Map.put(:metadata, %{})
          end)

        {:ok,
         %Result{
           prompts: prompts,
           commit_messages: CommitMessages.from_file(config.commit_messages_file),
           target_repos: config.target_repos,
           repo_groups: config.repo_groups || %{},
           source_root: config.config_dir,
           project_dir: config.project_dir,
           phase_names: config.phase_names,
           legacy_config: config
         }}
      end
    end
  end
end
