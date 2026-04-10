defmodule PromptRunner.FrontMatter do
  @moduledoc """
  Markdown front matter reader and writer used by Prompt Runner packet files.
  """

  @type document :: %{attributes: map(), body: String.t()}

  @spec load_file(String.t()) :: {:ok, document()} | {:error, term()}
  def load_file(path) when is_binary(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec parse(String.t()) :: {:ok, document()} | {:error, term()}
  def parse(content) when is_binary(content) do
    {yaml, body} = split(content)

    with {:ok, attrs} <- parse_yaml(yaml) do
      {:ok, %{attributes: attrs, body: body}}
    end
  end

  @spec dump(map(), String.t()) :: String.t()
  def dump(attrs, body \\ "") when is_map(attrs) and is_binary(body) do
    yaml = dump_yaml(attrs, 0)

    if String.trim(yaml) == "" do
      String.trim_trailing(body)
    else
      """
      ---
      #{yaml}
      ---
      #{String.trim_leading(body)}
      """
      |> String.trim_trailing()
      |> Kernel.<>("\n")
    end
  end

  @spec write_file(String.t(), map(), String.t()) :: :ok | {:error, term()}
  def write_file(path, attrs, body \\ "")
      when is_binary(path) and is_map(attrs) and is_binary(body) do
    path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(path, dump(attrs, body))
  end

  defp split(content) do
    case Regex.run(~r/\A---\n(.*?)\n---\n?(.*)\z/s, content, capture: :all_but_first) do
      [yaml, body] -> {yaml, body}
      _ -> {"", content}
    end
  end

  defp parse_yaml(yaml) do
    if String.trim(yaml) == "" do
      {:ok, %{}}
    else
      case YamlElixir.read_from_string(yaml) do
        {:ok, decoded} when is_map(decoded) -> {:ok, normalize(decoded)}
        {:ok, _other} -> {:error, :front_matter_not_a_map}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp normalize(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {to_string(key), normalize(inner)} end)
  end

  defp normalize(value) when is_list(value), do: Enum.map(value, &normalize/1)
  defp normalize(value), do: value

  defp dump_yaml(map, indent) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Enum.map_join("\n", fn {key, value} -> dump_entry(to_string(key), value, indent) end)
  end

  defp dump_entry(key, value, indent) when is_map(value) and map_size(value) > 0 do
    prefix = String.duplicate(" ", indent)
    "#{prefix}#{key}:\n#{dump_yaml(value, indent + 2)}"
  end

  defp dump_entry(key, value, indent) when is_map(value) and map_size(value) == 0 do
    prefix = String.duplicate(" ", indent)
    "#{prefix}#{key}: {}"
  end

  defp dump_entry(key, [], indent) do
    prefix = String.duplicate(" ", indent)
    "#{prefix}#{key}: []"
  end

  defp dump_entry(key, value, indent) when is_list(value) do
    prefix = String.duplicate(" ", indent)
    items = Enum.map_join(value, "\n", &dump_list_item(&1, indent + 2))
    "#{prefix}#{key}:\n#{items}"
  end

  defp dump_entry(key, value, indent) do
    prefix = String.duplicate(" ", indent)
    "#{prefix}#{key}: #{dump_scalar(value, indent)}"
  end

  defp dump_list_item(value, indent) when is_map(value) and map_size(value) > 0 do
    prefix = String.duplicate(" ", indent)

    lines =
      value
      |> dump_yaml(indent + 2)
      |> String.split("\n")

    case lines do
      [first | rest] ->
        (["#{prefix}- #{String.trim_leading(first)}"] ++
           Enum.map(rest, fn line ->
             "#{String.duplicate(" ", indent + 2)}#{String.trim_leading(line)}"
           end))
        |> Enum.join("\n")

      [] ->
        "#{prefix}- {}"
    end
  end

  defp dump_list_item(value, indent) when is_list(value) do
    prefix = String.duplicate(" ", indent)
    "#{prefix}- #{dump_scalar(value, indent)}"
  end

  defp dump_list_item(value, indent) do
    prefix = String.duplicate(" ", indent)
    "#{prefix}- #{dump_scalar(value, indent)}"
  end

  defp dump_scalar(value, _indent) when is_integer(value) or is_float(value), do: to_string(value)
  defp dump_scalar(true, _indent), do: "true"
  defp dump_scalar(false, _indent), do: "false"
  defp dump_scalar(nil, _indent), do: "null"
  defp dump_scalar([], _indent), do: "[]"

  defp dump_scalar(value, indent) when is_binary(value) do
    if String.contains?(value, "\n") do
      block_scalar(value, indent)
    else
      escaped =
        value
        |> String.replace("\\", "\\\\")
        |> String.replace("\"", "\\\"")

      "\"#{escaped}\""
    end
  end

  defp dump_scalar(value, _indent) when is_list(value) do
    values =
      value
      |> Enum.map_join(", ", fn item ->
        cond do
          is_binary(item) -> dump_scalar(item, 0)
          is_integer(item) or is_float(item) -> to_string(item)
          item in [true, false, nil] -> dump_scalar(item, 0)
          true -> "\"#{to_string(item)}\""
        end
      end)

    "[#{values}]"
  end

  defp dump_scalar(value, _indent), do: "\"#{to_string(value)}\""

  defp block_scalar(value, indent) do
    lines =
      value
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        "#{String.duplicate(" ", indent + 2)}#{line}"
      end)

    "|-\n#{lines}"
  end
end
