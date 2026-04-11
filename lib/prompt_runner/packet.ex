defmodule PromptRunner.Packet do
  @moduledoc """
  Packet manifest loader and generator.
  """

  alias PromptRunner.{FrontMatter, Paths, Profile, RecoveryConfig}
  alias PromptRunner.Runner
  alias PromptRunner.Source.PacketSource

  @manifest_file "prompt_runner_packet.md"

  @type repo_config :: %{name: String.t(), path: String.t(), default: boolean()}

  @type t :: %__MODULE__{
          root: String.t(),
          manifest_path: String.t(),
          name: String.t(),
          prompt_dir: String.t(),
          prompt_path: String.t(),
          profile_name: String.t() | nil,
          profile: map(),
          repos: [repo_config()],
          phase_names: map(),
          options: map(),
          body: String.t()
        }

  defstruct [
    :root,
    :manifest_path,
    :name,
    :prompt_dir,
    :prompt_path,
    :profile_name,
    :profile,
    :repos,
    :phase_names,
    :options,
    :body
  ]

  @spec manifest_file(String.t()) :: String.t()
  def manifest_file(root) when is_binary(root), do: Path.join(Paths.resolve(root), @manifest_file)

  @spec exists?(String.t()) :: boolean()
  def exists?(root) when is_binary(root), do: File.exists?(manifest_file(root))

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(root) when is_binary(root) do
    root = Paths.resolve(root)
    manifest_path = manifest_file(root)

    with {:ok, %{attributes: attrs, body: body}} <- FrontMatter.load_file(manifest_path),
         {:ok, profile} <- load_profile(attrs) do
      build_packet(root, manifest_path, attrs, profile, body)
    end
  end

  @spec new(String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(name, opts \\ []) when is_binary(name) do
    root =
      case opts[:root] do
        nil -> Paths.resolve(name)
        base -> Path.join(Paths.resolve(base), name)
      end

    File.mkdir_p!(Path.join(root, "prompts"))

    attrs =
      %{
        "name" => name,
        "profile" => opts[:profile] || default_profile_name(),
        "prompt_dir" => "prompts",
        "repos" => %{},
        "phases" => %{},
        "recovery" => packet_recovery_opts(opts)
      }
      |> maybe_put_attr("provider", opts[:provider])
      |> maybe_put_attr("model", opts[:model])
      |> maybe_put_attr("reasoning_effort", opts[:reasoning_effort])
      |> maybe_put_attr("permission_mode", opts[:permission_mode])
      |> maybe_put_attr("cli_confirmation", opts[:cli_confirmation])

    body = """
    # #{name}

    Packet manifest for Prompt Runner 0.7.0.
    """

    with :ok <- FrontMatter.write_file(Path.join(root, @manifest_file), attrs, body) do
      load(root)
    end
  end

  @spec add_repo(String.t(), String.t(), String.t(), keyword()) :: {:ok, t()} | {:error, term()}
  def add_repo(root, name, path, opts \\ [])
      when is_binary(root) and is_binary(name) and is_binary(path) do
    with {:ok, %{attributes: attrs, body: body}} <- FrontMatter.load_file(manifest_file(root)) do
      repos =
        attrs
        |> Map.get("repos", %{})
        |> stringify_keys()
        |> Map.put(name, %{"path" => path, "default" => opts[:default] || false})

      attrs = Map.put(attrs, "repos", repos)

      with :ok <- FrontMatter.write_file(manifest_file(root), attrs, body) do
        load(root)
      end
    end
  end

  @spec doctor(String.t()) :: {:ok, map()} | {:error, term()}
  def doctor(root) when is_binary(root) do
    with {:ok, packet} <- load(root),
         {:ok, provider_info} <- provider_info(packet.options) do
      repo_checks =
        Enum.map(packet.repos, fn repo ->
          %{
            name: repo.name,
            path: repo.path,
            exists?: File.dir?(repo.path)
          }
        end)

      prompt_files =
        packet.prompt_path
        |> Path.join("*.prompt.md")
        |> Path.wildcard()
        |> Enum.sort()

      {:ok,
       %{
         packet: packet.name,
         root: packet.root,
         manifest_path: packet.manifest_path,
         prompt_path: packet.prompt_path,
         profile: packet.profile_name,
         provider: packet.options["provider"],
         model: packet.options["model"],
         provider_info: provider_info,
         repos: repo_checks,
         prompt_files: prompt_files
       }}
    end
  end

  @spec explain(String.t()) :: {:ok, map()} | {:error, term()}
  def explain(root) when is_binary(root) do
    with {:ok, packet} <- load(root) do
      {:ok,
       %{
         packet: %{
           name: packet.name,
           root: packet.root,
           manifest_path: packet.manifest_path,
           prompt_path: packet.prompt_path,
           profile: packet.profile_name
         },
         repos: packet.repos,
         phase_names: packet.phase_names,
         options: packet.options
       }}
    end
  end

  @spec checklist_sync(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def checklist_sync(root) when is_binary(root) do
    with {:ok, packet} <- load(root),
         {:ok, result} <- PacketSource.load(packet.root, []) do
      paths =
        Enum.map(result.prompts, fn prompt ->
          checklist_path = checklist_path(packet.prompt_path, prompt.file)
          body = checklist_body(prompt)
          :ok = File.write!(checklist_path, body)
          checklist_path
        end)

      {:ok, paths}
    end
  end

  defp checklist_path(prompt_dir, prompt_file) do
    prompt_file
    |> Path.rootname(".md")
    |> Kernel.<>(".checklist.md")
    |> then(&Path.join(prompt_dir, &1))
  end

  defp checklist_body(prompt) do
    items = PromptRunner.Verifier.contract_items(prompt.verify || %{})

    lines =
      items
      |> Enum.map_join("\n", fn item -> "- [ ] #{item.label}" end)

    """
    # Checklist #{prompt.num}: #{prompt.name}

    Generated from the prompt verification contract.

    ## Verification Items

    #{lines}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp load_profile(attrs) do
    profile_name = attrs["profile"]

    case Profile.load(profile_name) do
      {:ok, profile} -> {:ok, profile}
      {:error, _reason} -> {:ok, %{name: nil, options: %{}, path: nil, body: ""}}
    end
  end

  defp build_packet(root, manifest_path, attrs, profile, body) do
    prompt_dir = attrs["prompt_dir"] || "prompts"
    prompt_path = Paths.resolve(prompt_dir, root)

    packet = %__MODULE__{
      root: root,
      manifest_path: manifest_path,
      name: attrs["name"] || Path.basename(root),
      prompt_dir: prompt_dir,
      prompt_path: prompt_path,
      profile_name: profile.name,
      profile: profile.options,
      repos: normalize_repos(attrs["repos"], root),
      phase_names: normalize_phases(attrs["phases"]),
      options: merged_options(profile.options, attrs),
      body: body
    }

    {:ok, packet}
  end

  defp normalize_repos(nil, _root), do: []

  defp normalize_repos(repos, root) when is_map(repos) do
    repos
    |> stringify_keys()
    |> Enum.map(fn {name, attrs} ->
      attrs = stringify_keys(attrs)

      %{
        name: name,
        path: Paths.resolve(attrs["path"], root),
        default: attrs["default"] == true
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_repos(repos, root) when is_list(repos) do
    repos
    |> Enum.map(fn repo ->
      repo = stringify_keys(repo)

      %{
        name: repo["name"],
        path: Paths.resolve(repo["path"], root),
        default: repo["default"] == true
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp normalize_repos(_other, _root), do: []

  defp normalize_phases(nil), do: %{}

  defp normalize_phases(phases) when is_map(phases) do
    phases
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case normalize_phase_key(key) do
        nil -> acc
        phase -> Map.put(acc, phase, to_string(value))
      end
    end)
  end

  defp normalize_phases(_other), do: %{}

  defp normalize_phase_key(key) when is_integer(key), do: key

  defp normalize_phase_key(key) when is_binary(key) do
    case Integer.parse(key) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp normalize_phase_key(_key), do: nil

  defp merged_options(profile_options, attrs) do
    packet_options =
      attrs
      |> stringify_keys()
      |> Map.take([
        "provider",
        "model",
        "reasoning_effort",
        "permission_mode",
        "allowed_tools",
        "adapter_opts",
        "claude_opts",
        "codex_opts",
        "codex_thread_opts",
        "gemini_opts",
        "amp_opts",
        "system_prompt",
        "append_system_prompt",
        "max_turns",
        "cli_confirmation",
        "timeout",
        "log_mode",
        "log_meta",
        "events_mode",
        "tool_output",
        "recovery"
      ])

    profile_options
    |> stringify_keys()
    |> Map.merge(packet_options)
    |> maybe_put_codex_reasoning()
    |> then(fn opts -> Map.put(opts, "recovery", RecoveryConfig.normalize(opts)) end)
  end

  defp maybe_put_codex_reasoning(%{"reasoning_effort" => value} = opts)
       when is_binary(value) and value != "" do
    codex_thread_opts =
      opts
      |> Map.get("codex_thread_opts", %{})
      |> stringify_keys()
      |> Map.put("reasoning_effort", value)

    Map.put(opts, "codex_thread_opts", codex_thread_opts)
  end

  defp maybe_put_codex_reasoning(opts), do: opts

  defp provider_info(options) do
    provider =
      case Map.get(options, "provider", "codex") do
        value when is_atom(value) -> value
        value when is_binary(value) -> String.to_atom(value)
      end

    Runner.check_provider_runtime(provider)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp default_profile_name do
    Profile.default_profile_name() |> elem(1)
  end

  defp packet_recovery_opts(opts) do
    base =
      case opts[:recovery] do
        recovery when is_map(recovery) -> recovery
        _ -> RecoveryConfig.default()
      end

    base
    |> put_path(["resume_attempts"], opts[:resume_attempts])
    |> put_path(["retry", "max_attempts"], opts[:retry_attempts])
    |> put_path(["retry", "base_delay_ms"], opts[:retry_base_delay_ms])
    |> put_path(["retry", "max_delay_ms"], opts[:retry_max_delay_ms])
    |> put_path(["retry", "jitter"], opts[:retry_jitter])
    |> put_path(["repair", "enabled"], opts[:auto_repair])
    |> put_path(["repair", "max_attempts"], opts[:repair_attempts])
    |> then(&RecoveryConfig.normalize(%{"recovery" => &1}))
  end

  defp put_path(map, _path, nil), do: map
  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    nested =
      map
      |> Map.get(key, %{})
      |> put_path(rest, value)

    Map.put(map, key, nested)
  end

  defp maybe_put_attr(attrs, _key, nil), do: attrs
  defp maybe_put_attr(attrs, key, value), do: Map.put(attrs, key, value)
end
