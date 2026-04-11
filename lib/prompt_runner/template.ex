defmodule PromptRunner.Template do
  @moduledoc """
  Prompt scaffold templates.

  Templates are markdown documents with YAML front matter. Template front matter
  provides default prompt metadata, while the body provides the authoring
  scaffold. Dynamic prompt attributes are merged in by Prompt Runner when a new
  prompt is created.
  """

  alias PromptRunner.{FrontMatter, Profile}

  @default_name "default"
  @from_adr_name "from-adr"
  @placeholder_marker "prompt_runner:placeholder"

  @type loaded_template :: %{
          name: String.t(),
          path: String.t() | nil,
          source: :packet | :home | :builtin,
          attributes: map(),
          body: String.t()
        }

  @default_template """
  ---
  references: []
  required_reading: []
  context_files: []
  depends_on: []
  verify:
    files_exist: []
    contains: []
    changed_paths_only: []
  ---
  # {{name}}

  ## Required Reading

  <!-- prompt_runner:placeholder required_reading -->
  - Add ADRs, specs, and source docs here.

  ## Mission

  <!-- prompt_runner:placeholder mission -->
  Describe the exact work to perform.

  ## Deliverables

  <!-- prompt_runner:placeholder deliverables -->
  - List the exact files, outputs, or behavior changes required.

  ## Non-Goals

  <!-- prompt_runner:placeholder non_goals -->
  - List what must stay unchanged.

  ## Verification Notes

  <!-- prompt_runner:placeholder verification_notes -->
  - Translate deliverables into deterministic `verify:` entries.
  """

  @from_adr_template """
  ---
  references: []
  required_reading: []
  context_files: []
  depends_on: []
  verify:
    files_exist: []
    contains: []
    changed_paths_only: []
  ---
  # {{name}}

  ## Required Reading

  <!-- prompt_runner:placeholder required_reading -->
  - Add the ADRs and packet-local source docs that govern this prompt.

  ## Architecture Context

  <!-- prompt_runner:placeholder architecture_context -->
  - Summarize the decisions that matter from the required reading.

  ## Mission

  <!-- prompt_runner:placeholder mission -->
  Describe the concrete repo work to perform.

  ## Deliverables

  <!-- prompt_runner:placeholder deliverables -->
  - List the exact files, interfaces, docs, or behavior changes required.

  ## Non-Goals

  <!-- prompt_runner:placeholder non_goals -->
  - List what this prompt must not change.

  ## Verification Notes

  <!-- prompt_runner:placeholder verification_notes -->
  - Map each deliverable to `verify:` entries before running the packet.
  """

  @builtins %{
    @default_name => @default_template,
    @from_adr_name => @from_adr_template
  }

  @spec templates_dir() :: String.t()
  def templates_dir, do: Path.join(Profile.config_home(), "templates")

  @spec default_name() :: String.t()
  def default_name, do: @default_name

  @spec template_path(String.t()) :: String.t()
  def template_path(name) when is_binary(name) do
    Path.join(templates_dir(), "#{name}.prompt.md")
  end

  @spec packet_templates_dir(String.t()) :: String.t()
  def packet_templates_dir(packet_root) when is_binary(packet_root) do
    Path.join(packet_root, "templates")
  end

  @spec packet_template_path(String.t(), String.t()) :: String.t()
  def packet_template_path(packet_root, name)
      when is_binary(packet_root) and is_binary(name) do
    Path.join(packet_templates_dir(packet_root), "#{name}.prompt.md")
  end

  @spec init() ::
          {:ok,
           %{
             templates_dir: String.t(),
             default_template_file: String.t(),
             from_adr_template_file: String.t()
           }}
  def init do
    File.mkdir_p!(templates_dir())

    unless File.exists?(template_path(@default_name)) do
      File.write!(template_path(@default_name), @default_template)
    end

    unless File.exists?(template_path(@from_adr_name)) do
      File.write!(template_path(@from_adr_name), @from_adr_template)
    end

    {:ok,
     %{
       templates_dir: templates_dir(),
       default_template_file: template_path(@default_name),
       from_adr_template_file: template_path(@from_adr_name)
     }}
  end

  @spec list(String.t() | nil) :: {:ok, [map()]}
  def list(packet_root \\ nil) do
    entries =
      builtin_entries()
      |> merge_entries(home_entries())
      |> merge_entries(packet_entries(packet_root))
      |> Enum.sort_by(& &1.name)

    {:ok, entries}
  end

  @spec load(String.t() | nil, keyword()) :: {:ok, loaded_template()} | {:error, term()}
  def load(name_or_path \\ nil, opts \\ [])

  def load(nil, opts) do
    name = opts[:default] || @default_name
    load(name, opts)
  end

  def load(name_or_path, opts) when is_binary(name_or_path) do
    packet_root = opts[:packet_root]

    cond do
      explicit_template_path?(name_or_path) ->
        load_explicit_path(name_or_path)

      is_binary(packet_root) and File.exists?(packet_template_path(packet_root, name_or_path)) ->
        load_file(packet_template_path(packet_root, name_or_path), name_or_path, :packet)

      File.exists?(template_path(name_or_path)) ->
        load_file(template_path(name_or_path), name_or_path, :home)

      Map.has_key?(@builtins, name_or_path) ->
        load_builtin(name_or_path)

      true ->
        {:error, {:template_not_found, name_or_path}}
    end
  end

  @spec render(map(), loaded_template()) :: {map(), String.t()}
  def render(attrs, %{attributes: template_attrs, body: body, name: name})
      when is_map(attrs) and is_map(template_attrs) and is_binary(body) do
    merged_attrs =
      template_attrs
      |> deep_merge(attrs)
      |> Map.put_new("template", name)

    {merged_attrs, render_body(body, merged_attrs)}
  end

  @spec contains_placeholder_markers?(String.t() | nil) :: boolean()
  def contains_placeholder_markers?(body) when is_binary(body) do
    String.contains?(body, @placeholder_marker)
  end

  def contains_placeholder_markers?(_body), do: false

  defp builtin_entries do
    Enum.map(@builtins, fn {name, _doc} ->
      %{name: name, source: :builtin, path: nil}
    end)
  end

  defp home_entries do
    templates_dir()
    |> Path.join("*.prompt.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      %{name: Path.basename(path, ".prompt.md"), source: :home, path: path}
    end)
  end

  defp packet_entries(nil), do: []

  defp packet_entries(packet_root) when is_binary(packet_root) do
    packet_templates_dir(packet_root)
    |> Path.join("*.prompt.md")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      %{name: Path.basename(path, ".prompt.md"), source: :packet, path: path}
    end)
  end

  defp merge_entries(base, overrides) do
    override_index = Map.new(overrides, &{&1.name, &1})

    base
    |> Enum.reject(&Map.has_key?(override_index, &1.name))
    |> Kernel.++(overrides)
  end

  defp explicit_template_path?(path) do
    Path.type(path) == :absolute or String.contains?(path, "/") or String.ends_with?(path, ".md")
  end

  defp load_explicit_path(path) do
    name =
      path
      |> Path.basename()
      |> String.replace_suffix(".prompt.md", "")
      |> String.replace_suffix(".md", "")

    load_file(path, name, :home)
  end

  defp load_file(path, name, source) do
    with {:ok, %{attributes: attrs, body: body}} <- FrontMatter.load_file(path) do
      {:ok, %{name: name, path: path, source: source, attributes: attrs, body: body}}
    end
  end

  defp load_builtin(name) do
    with {:ok, %{attributes: attrs, body: body}} <- FrontMatter.parse(Map.fetch!(@builtins, name)) do
      {:ok, %{name: name, path: nil, source: :builtin, attributes: attrs, body: body}}
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, left_value, right_value ->
      if is_map(left_value) and is_map(right_value) do
        deep_merge(left_value, right_value)
      else
        right_value
      end
    end)
  end

  defp render_body(body, attrs) do
    replacements = replacement_map(attrs)

    Enum.reduce(replacements, body, fn {key, value}, acc ->
      String.replace(acc, "{{#{key}}}", value)
    end)
  end

  defp replacement_map(attrs) do
    targets = List.wrap(attrs["targets"])

    %{
      "id" => to_string(attrs["id"] || ""),
      "phase" => to_string(attrs["phase"] || ""),
      "name" => to_string(attrs["name"] || ""),
      "commit" => to_string(attrs["commit"] || ""),
      "targets_csv" => Enum.join(targets, ", "),
      "targets_bullets" =>
        case targets do
          [] -> "- Add target repos here."
          values -> Enum.map_join(values, "\n", &"- `#{&1}`")
        end
    }
  end
end
