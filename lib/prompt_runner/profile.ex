defmodule PromptRunner.Profile do
  @moduledoc """
  Home-scoped Prompt Runner profiles.
  """

  alias PromptRunner.FrontMatter

  @default_profile "codex-default"

  @type t :: %{
          name: String.t(),
          path: String.t(),
          options: map(),
          body: String.t()
        }

  @spec config_home() :: String.t()
  def config_home do
    System.get_env("PROMPT_RUNNER_CONFIG_HOME") ||
      Path.join([System.user_home!(), ".config", "prompt_runner"])
  end

  @spec config_file() :: String.t()
  def config_file, do: Path.join(config_home(), "config.md")

  @spec profiles_dir() :: String.t()
  def profiles_dir, do: Path.join(config_home(), "profiles")

  @spec profile_path(String.t()) :: String.t()
  def profile_path(name) when is_binary(name) do
    Path.join(profiles_dir(), "#{name}.md")
  end

  @spec init(keyword()) :: {:ok, %{config_file: String.t(), profile_file: String.t()}}
  def init(opts \\ []) do
    default_profile = opts[:default_profile] || @default_profile

    File.mkdir_p!(profiles_dir())

    unless File.exists?(config_file()) do
      :ok =
        FrontMatter.write_file(
          config_file(),
          %{"default_profile" => default_profile},
          "# Prompt Runner Config\n"
        )
    end

    unless File.exists?(profile_path(default_profile)) do
      {:ok, _profile} = create(default_profile, default_profile_options())
    end

    {:ok, %{config_file: config_file(), profile_file: profile_path(default_profile)}}
  end

  @spec create(String.t(), map()) :: {:ok, t()} | {:error, term()}
  def create(name, attrs) when is_binary(name) and is_map(attrs) do
    File.mkdir_p!(profiles_dir())

    merged_attrs =
      default_profile_options()
      |> Map.merge(stringify_keys(attrs))

    path = profile_path(name)

    with :ok <- FrontMatter.write_file(path, merged_attrs, "# Profile #{name}\n") do
      load(name)
    end
  end

  @spec list() :: {:ok, [String.t()]}
  def list do
    File.mkdir_p!(profiles_dir())

    profiles =
      profiles_dir()
      |> Path.join("*.md")
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, ".md"))
      |> Enum.sort()

    {:ok, profiles}
  end

  @spec load(String.t() | nil) :: {:ok, t()} | {:error, term()}
  def load(name \\ nil)

  def load(nil) do
    with {:ok, default_profile} <- default_profile_name() do
      load(default_profile)
    end
  end

  def load(name) when is_binary(name) do
    path = profile_path(name)

    with {:ok, %{attributes: attrs, body: body}} <- FrontMatter.load_file(path) do
      {:ok, %{name: name, path: path, options: normalize_options(attrs), body: body}}
    end
  end

  @spec global_defaults() :: map()
  def global_defaults do
    case load() do
      {:ok, profile} -> profile.options
      {:error, _reason} -> %{}
    end
  end

  @spec default_profile_name() :: {:ok, String.t()} | {:error, term()}
  def default_profile_name do
    case FrontMatter.load_file(config_file()) do
      {:ok, %{attributes: %{"default_profile" => value}}} when is_binary(value) and value != "" ->
        {:ok, value}

      _ ->
        {:ok, @default_profile}
    end
  end

  defp default_profile_options do
    %{
      "provider" => "codex",
      "model" => "gpt-5.4",
      "reasoning_effort" => "xhigh",
      "permission_mode" => "bypass",
      "allowed_tools" => ["Read", "Edit", "Write", "Bash"],
      "cli_confirmation" => "require",
      "log_mode" => "compact",
      "log_meta" => "none",
      "events_mode" => "compact",
      "tool_output" => "summary",
      "retry_attempts" => 2,
      "auto_repair" => true
    }
  end

  defp normalize_options(attrs) do
    attrs
    |> stringify_keys()
    |> maybe_put_codex_reasoning()
    |> maybe_put_runtime_defaults()
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

  defp maybe_put_runtime_defaults(opts) do
    opts
    |> Map.put_new("retry_attempts", 2)
    |> Map.put_new("auto_repair", true)
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
