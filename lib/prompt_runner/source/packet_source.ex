defmodule PromptRunner.Source.PacketSource do
  @moduledoc """
  Source implementation for Prompt Runner packet directories.
  """

  @behaviour PromptRunner.Source

  alias PromptRunner.Packet
  alias PromptRunner.Source
  alias PromptRunner.Source.DirectorySource

  @impl true
  def load(root, opts) when is_binary(root) do
    with {:ok, packet} <- Packet.load(root),
         {:ok, %Source.Result{} = result} <- DirectorySource.load(packet.prompt_path, opts) do
      prompt_overrides = prompt_overrides(result.prompts)

      {:ok,
       %Source.Result{
         prompts: result.prompts,
         commit_messages: build_commit_messages(result.prompts, packet.repos),
         target_repos: packet.repos,
         repo_groups: %{},
         source_root: packet.root,
         project_dir: packet.root,
         phase_names: packet.phase_names,
         metadata: %{
           packet: packet,
           options: Map.put(packet.options, "prompt_overrides", prompt_overrides)
         },
         legacy_config: nil
       }}
    end
  end

  defp build_commit_messages(prompts, repos) do
    Enum.reduce(prompts, %{}, &put_prompt_commit_message(&2, &1, repos))
  end

  defp put_prompt_commit_message(acc, %{commit_message: nil}, _repos), do: acc

  defp put_prompt_commit_message(
         acc,
         %{commit_message: message, target_repos: target_repos} = prompt,
         _repos
       )
       when is_binary(message) and target_repos in [nil, []] do
    Map.put(acc, {prompt.num, nil}, message)
  end

  defp put_prompt_commit_message(acc, %{commit_message: message} = prompt, repos)
       when is_binary(message) do
    Enum.reduce(target_repos(prompt, repos), acc, fn repo_name, inner_acc ->
      Map.put(inner_acc, {prompt.num, repo_name}, message)
    end)
  end

  defp put_prompt_commit_message(acc, _prompt, _repos), do: acc

  defp target_repos(%{target_repos: target_repos}, _repos) when is_list(target_repos) do
    target_repos
  end

  defp target_repos(_prompt, repos) do
    repos
    |> Enum.filter(& &1.default)
    |> Enum.map(& &1.name)
  end

  defp prompt_overrides(prompts) do
    prompts
    |> Enum.reduce(%{}, fn prompt, acc ->
      case Map.get(prompt.metadata || %{}, "llm_override", %{}) do
        override when is_map(override) and map_size(override) > 0 ->
          Map.put(acc, prompt.num, override)

        _ ->
          acc
      end
    end)
  end
end
