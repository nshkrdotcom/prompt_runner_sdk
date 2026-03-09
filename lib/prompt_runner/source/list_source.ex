defmodule PromptRunner.Source.ListSource do
  @moduledoc """
  Source implementation for in-memory `%PromptRunner.Prompt{}` lists.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.Prompt
  alias PromptRunner.Source.Result

  @impl true
  def load(prompts, _opts) when is_list(prompts) do
    normalized =
      prompts
      |> Enum.with_index(1)
      |> Enum.map(fn {prompt, index} -> normalize_prompt(prompt, index) end)

    {:ok,
     %Result{
       prompts: normalized,
       commit_messages: commit_messages_for(normalized),
       source_root: File.cwd!(),
       project_dir: File.cwd!()
     }}
  end

  defp normalize_prompt(%Prompt{} = prompt, index) do
    prompt
    |> Map.put_new(:num, index |> Integer.to_string() |> String.pad_leading(2, "0"))
    |> Map.put_new(:phase, 1)
    |> Map.put_new(:sp, 1)
    |> Map.put_new(:name, "Prompt #{index}")
    |> Map.put_new(:metadata, %{})
    |> Map.put_new(:validation_commands, [])
  end

  defp commit_messages_for(prompts) do
    Enum.reduce(prompts, %{}, fn prompt, acc ->
      if is_binary(prompt.commit_message) and prompt.commit_message != "" do
        Map.put(acc, {prompt.num, nil}, prompt.commit_message)
      else
        acc
      end
    end)
  end
end
