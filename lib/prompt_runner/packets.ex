defmodule PromptRunner.Packets do
  @moduledoc """
  Prompt operations within a packet.
  """

  alias PromptRunner.{FrontMatter, Packet, Prompt, Template}
  alias PromptRunner.Source.PacketSource

  @spec create_prompt(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def create_prompt(packet_root, attrs, _opts \\ [])
      when is_binary(packet_root) and is_map(attrs) do
    with {:ok, packet} <- Packet.load(packet_root),
         prompt_attrs = build_prompt_attrs(packet, attrs),
         {:ok, template} <- resolve_template(packet, prompt_attrs),
         {prompt_attrs, body} <- Template.render(prompt_attrs, template),
         path <- prompt_path(packet, prompt_attrs),
         :ok <- FrontMatter.write_file(path, prompt_attrs, body) do
      {:ok, path}
    end
  end

  @spec list_prompts(String.t()) :: {:ok, [Prompt.t()]} | {:error, term()}
  def list_prompts(packet_root) when is_binary(packet_root) do
    with {:ok, result} <- PacketSource.load(packet_root, []) do
      {:ok, result.prompts}
    end
  end

  @spec load_prompt(String.t(), String.t()) :: {:ok, Prompt.t()} | {:error, term()}
  def load_prompt(packet_root, prompt_id) when is_binary(packet_root) and is_binary(prompt_id) do
    with {:ok, prompts} <- list_prompts(packet_root) do
      case Enum.find(prompts, &(&1.num == normalize_id(prompt_id))) do
        nil -> {:error, {:prompt_not_found, prompt_id}}
        prompt -> {:ok, prompt}
      end
    end
  end

  @doc """
  Writes an amendment back into the packet's own prompt file.

  A separate explicit act, never a side effect of amending a run: the packet is
  a versioned artifact, and changing what a prompt requires is a commit
  somebody should be able to review.
  """
  @spec amend_prompt_contract(String.t(), String.t(), map()) :: :ok | {:error, term()}
  def amend_prompt_contract(packet_root, prompt_id, amendment)
      when is_binary(packet_root) and is_binary(prompt_id) and is_map(amendment) do
    with {:ok, prompt} <- load_prompt(packet_root, prompt_id),
         path when is_binary(path) <- prompt_file_path(packet_root, prompt),
         {:ok, content} <- File.read(path),
         {:ok, %{attributes: attrs, body: body}} <- FrontMatter.parse(content) do
      verify =
        attrs
        |> Map.get("verify", %{})
        |> apply_contract_amendment(amendment)

      FrontMatter.write_file(path, Map.put(attrs, "verify", verify), body)
    else
      nil -> {:error, {:prompt_file_not_found, prompt_id}}
      error -> error
    end
  end

  defp prompt_file_path(_packet_root, %{origin: %{path: path}}) when is_binary(path), do: path

  defp prompt_file_path(packet_root, %{file: file}) when is_binary(file) do
    case Packet.load(packet_root) do
      {:ok, packet} -> Path.join(packet.prompt_path, file)
      {:error, _reason} -> nil
    end
  end

  defp prompt_file_path(_packet_root, _prompt), do: nil

  defp apply_contract_amendment(verify, %{operation: :drop, clause: clause}),
    do: verify |> stringify_keys() |> Map.delete(clause)

  defp apply_contract_amendment(verify, %{operation: :replace} = amendment),
    do: verify |> stringify_keys() |> Map.put(amendment.clause, amendment.entries)

  defp apply_contract_amendment(verify, %{operation: :add} = amendment) do
    verify = stringify_keys(verify)
    existing = verify |> Map.get(amendment.clause, []) |> List.wrap()
    Map.put(verify, amendment.clause, existing ++ List.wrap(amendment.entries))
  end

  defp apply_contract_amendment(verify, _amendment), do: stringify_keys(verify)

  @spec sync_checklists(String.t()) ::
          {:ok, %{paths: [String.t()], warnings: [map()]}} | {:error, term()}
  def sync_checklists(packet_root), do: Packet.checklist_sync(packet_root)

  defp default_targets(%Packet{repos: [%{name: name, default: true} | _rest]}), do: [name]
  defp default_targets(%Packet{repos: [%{name: name} | _rest]}), do: [name]
  defp default_targets(_packet), do: []

  defp build_prompt_attrs(packet, attrs) do
    attrs = stringify_keys(attrs)
    id = normalize_id(Map.get(attrs, "id", "01"))
    name = Map.get(attrs, "name", "New Prompt")
    phase = Map.get(attrs, "phase", 1)

    attrs
    |> Map.merge(%{
      "id" => id,
      "phase" => phase,
      "name" => name,
      "targets" => Map.get(attrs, "targets", default_targets(packet)),
      "commit" => Map.get(attrs, "commit", default_commit(name))
    })
    |> Map.put_new("verify", %{})
  end

  defp prompt_path(packet, %{"id" => id, "name" => name}) do
    Path.join(packet.prompt_path, "#{id}_#{slugify(name)}.prompt.md")
  end

  defp resolve_template(packet, prompt_attrs) do
    template_name =
      prompt_attrs["template"] ||
        packet.options["prompt_template"] ||
        Template.default_name()

    Template.load(template_name, packet_root: packet.root, default: Template.default_name())
  end

  defp default_commit(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    "chore: #{slug}"
  end

  defp normalize_id(value) when is_integer(value),
    do: value |> Integer.to_string() |> String.pad_leading(2, "0")

  defp normalize_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.to_integer()
    |> normalize_id()
  end

  defp slugify(value) do
    value
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "_")
    |> String.trim("_")
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value
end
