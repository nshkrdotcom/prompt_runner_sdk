defmodule PromptRunner.RepoTargets do
  @moduledoc false

  @type error ::
          {:unknown_group, String.t()}
          | {:cycle, list(String.t())}
          | {:invalid_group_value, String.t(), term()}

  @spec expand(list(String.t()) | nil, map() | nil) :: {list(String.t()) | nil, list(error())}
  def expand(nil, _repo_groups), do: {nil, []}

  def expand(targets, repo_groups) when is_list(targets) do
    repo_groups = repo_groups || %{}

    {expanded, errors} =
      Enum.reduce(targets, {[], []}, fn target, {acc, acc_errors} ->
        {names, errors} = expand_target(target, repo_groups, [])
        {acc ++ names, acc_errors ++ errors}
      end)

    {Enum.uniq(expanded), errors}
  end

  @spec expand!(list(String.t()) | nil, map() | nil) :: list(String.t()) | nil
  def expand!(targets, repo_groups) do
    {expanded, errors} = expand(targets, repo_groups)

    case errors do
      [] ->
        expanded

      [error | _] ->
        raise format_error(error)
    end
  end

  defp expand_target("@" <> group_name, repo_groups, stack) do
    if group_name in stack do
      {[], [{:cycle, Enum.reverse([group_name | stack])}]}
    else
      expand_group(group_name, repo_groups, stack)
    end
  end

  defp expand_target(target, _repo_groups, _stack) when is_binary(target) do
    {[target], []}
  end

  defp expand_target(target, _repo_groups, _stack) do
    {[], [{:invalid_group_value, "(prompt targets)", target}]}
  end

  defp expand_group(group_name, repo_groups, stack) do
    case Map.get(repo_groups, group_name) do
      nil ->
        {[], [{:unknown_group, group_name}]}

      members when is_list(members) ->
        expand_members(members, repo_groups, [group_name | stack])

      other ->
        {[], [{:invalid_group_value, group_name, other}]}
    end
  end

  defp expand_members(members, repo_groups, stack) do
    Enum.reduce(members, {[], []}, fn member, {acc, acc_errors} ->
      {names, errors} = expand_target(member, repo_groups, stack)
      {acc ++ names, acc_errors ++ errors}
    end)
  end

  @spec format_error(error()) :: String.t()
  def format_error({:unknown_group, group_name}), do: "Unknown repo group: @#{group_name}"

  def format_error({:cycle, group_path}) do
    "Repo group cycle detected: " <> Enum.map_join(group_path, " -> ", &"@#{&1}")
  end

  def format_error({:invalid_group_value, group_name, value}) do
    "Invalid repo group definition for @#{group_name}: #{inspect(value)}"
  end
end
