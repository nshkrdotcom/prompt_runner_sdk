defmodule PromptRunner.ProviderOptions do
  @moduledoc false

  @common_keys [
    :cli_path,
    :env,
    :args,
    :debug,
    :ollama,
    :ollama_model,
    :ollama_base_url,
    :ollama_http,
    :ollama_timeout_ms
  ]

  @provider_keys %{
    claude: [
      :model,
      :system_prompt,
      :provider_backend,
      :external_model_overrides,
      :anthropic_base_url,
      :anthropic_auth_token,
      :include_thinking,
      :max_turns,
      :append_system_prompt
    ],
    codex: [
      :model,
      :system_prompt,
      :reasoning_effort,
      :provider_backend,
      :model_provider,
      :oss_provider,
      :skip_git_repo_check,
      :output_schema,
      :additional_directories
    ],
    gemini: [
      :model,
      :system_prompt,
      :sandbox,
      :extensions
    ],
    amp: [
      :model,
      :mode,
      :include_thinking,
      :permissions,
      :mcp_config,
      :tools
    ]
  }

  @prompt_control_keys [:system_prompt, :append_system_prompt, :max_turns, :permission_mode]

  @prompt_control_support %{
    claude: MapSet.new([:system_prompt, :append_system_prompt, :max_turns, :permission_mode]),
    codex: MapSet.new([:system_prompt, :permission_mode]),
    gemini: MapSet.new([:system_prompt, :permission_mode]),
    amp: MapSet.new([:permission_mode])
  }

  @section_providers %{
    claude_opts: :claude,
    codex_opts: :codex,
    codex_thread_opts: :codex,
    gemini_opts: :gemini,
    amp_opts: :amp
  }

  @spec common_keys() :: [atom()]
  def common_keys, do: @common_keys

  @spec prompt_control_keys() :: [atom()]
  def prompt_control_keys, do: @prompt_control_keys

  @spec keys_for(atom()) :: [atom()]
  def keys_for(provider), do: Map.get(@provider_keys, canonical_provider(provider), [])

  @spec supported_keys(atom()) :: [atom()]
  def supported_keys(provider), do: Enum.uniq(@common_keys ++ keys_for(provider))

  @spec section_provider(atom()) :: atom() | nil
  def section_provider(section), do: Map.get(@section_providers, section)

  @spec unsupported_prompt_controls(atom(), map() | keyword()) :: [atom()]
  def unsupported_prompt_controls(provider, opts) when is_atom(provider) do
    supported =
      provider
      |> canonical_provider()
      |> then(&Map.get(@prompt_control_support, &1, MapSet.new()))

    opts
    |> normalize_opts_map()
    |> Enum.filter(fn {key, value} ->
      key in @prompt_control_keys and not is_nil(value) and not MapSet.member?(supported, key)
    end)
    |> Enum.map(&elem(&1, 0))
  end

  @spec validate(atom(), [map() | keyword() | nil]) ::
          :ok | {:error, {:unsupported_provider_option, atom()}}
  def validate(provider, sections) when is_atom(provider) and is_list(sections) do
    allowed_keys = supported_keys(provider)

    unknown_keys =
      sections
      |> Enum.map(&normalize_opts_map/1)
      |> Enum.reduce(%{}, &Map.merge(&2, &1))
      |> Map.keys()
      |> Enum.reject(&(&1 in allowed_keys))

    case unknown_keys do
      [] -> :ok
      [unknown | _rest] -> {:error, {:unsupported_provider_option, unknown}}
    end
  end

  @spec validate_section(atom(), map() | keyword() | nil) ::
          :ok | {:error, {:unsupported_provider_option, atom()}}
  def validate_section(section, opts) when is_atom(section) do
    case section_provider(section) do
      nil -> :ok
      provider -> validate(provider, [opts])
    end
  end

  defp canonical_provider(:codex_exec), do: :codex
  defp canonical_provider(provider), do: provider

  defp normalize_opts_map(nil), do: %{}

  defp normalize_opts_map(opts) when is_list(opts) do
    opts
    |> Keyword.new()
    |> Map.new(fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_opts_map(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {normalize_key(key), value} end)
  end

  defp normalize_opts_map(_opts), do: %{}

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    key
    |> String.trim()
    |> String.to_atom()
  end

  defp normalize_key(key), do: key
end
