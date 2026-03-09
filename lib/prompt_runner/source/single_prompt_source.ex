defmodule PromptRunner.Source.SinglePromptSource do
  @moduledoc """
  Source implementation for one raw prompt string.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.Prompt
  alias PromptRunner.Source.Result

  @impl true
  def load(prompt_text, opts) when is_binary(prompt_text) do
    name = opts[:name] || "Ad Hoc Prompt"
    commit = opts[:commit_message] || "chore: run ad hoc prompt"

    {:ok,
     %Result{
       prompts: [
         %Prompt{
           num: "01",
           phase: 1,
           sp: 1,
           name: name,
           file: nil,
           body: prompt_text,
           origin: %{type: :inline},
           target_repos: nil,
           commit_message: commit,
           validation_commands: [],
           metadata: %{}
         }
       ],
       commit_messages: %{{"01", nil} => commit},
       source_root: File.cwd!(),
       project_dir: opts[:target] || File.cwd!()
     }}
  end
end
