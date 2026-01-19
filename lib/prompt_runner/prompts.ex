defmodule PromptRunner.Prompts do
  @moduledoc false

  alias PromptRunner.Prompt

  @spec list(PromptRunner.Config.t()) :: [Prompt.t()]
  def list(config) do
    config.prompts_file
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.starts_with?(&1, "#") || &1 == ""))
    |> Enum.map(&parse_prompt_line/1)
  end

  @spec get(PromptRunner.Config.t(), String.t()) :: Prompt.t() | nil
  def get(config, num) do
    list(config) |> Enum.find(&(&1.num == num))
  end

  @spec nums(PromptRunner.Config.t()) :: [String.t()]
  def nums(config) do
    list(config) |> Enum.map(& &1.num) |> Enum.sort()
  end

  @spec phase_nums(PromptRunner.Config.t(), integer()) :: [String.t()]
  def phase_nums(config, phase) do
    list(config)
    |> Enum.filter(&(&1.phase == phase))
    |> Enum.map(& &1.num)
    |> Enum.sort()
  end

  defp parse_prompt_line(line) do
    case String.split(line, "|", parts: 6) do
      [num, phase, sp, name, file, target_repos] ->
        %Prompt{
          num: num,
          phase: String.to_integer(phase),
          sp: String.to_integer(sp),
          name: name,
          file: file,
          target_repos: parse_target_repos(target_repos)
        }

      [num, phase, sp, name, file] ->
        %Prompt{
          num: num,
          phase: String.to_integer(phase),
          sp: String.to_integer(sp),
          name: name,
          file: file,
          target_repos: nil
        }

      _ ->
        raise "Invalid prompt line: #{line}"
    end
  end

  defp parse_target_repos(""), do: nil

  defp parse_target_repos(target_repos) when is_binary(target_repos) do
    target_repos
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
  end
end
