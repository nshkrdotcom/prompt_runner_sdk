defmodule PromptRunner.Config do
  @moduledoc """
  Loads and normalizes configuration for the prompt runner.
  """

  alias AgentSessionManager.PermissionMode
  alias PromptRunner.LLM
  alias PromptRunner.LLMFacade
  alias PromptRunner.RepoTargets
  alias PromptRunner.UI

  @type repo_config :: %{name: String.t(), path: String.t(), default: boolean()}

  @type t :: %__MODULE__{
          config_dir: String.t(),
          project_dir: String.t() | nil,
          target_repos: [repo_config()] | nil,
          repo_groups: map(),
          prompts_file: String.t(),
          commit_messages_file: String.t(),
          progress_file: String.t(),
          log_dir: String.t(),
          llm_sdk: LLM.sdk(),
          model: String.t(),
          prompt_overrides: map(),
          allowed_tools: list() | nil,
          permission_mode: atom() | nil,
          adapter_opts: map(),
          claude_opts: map(),
          codex_opts: map(),
          codex_thread_opts: map(),
          cli_confirmation: :off | :warn | :require,
          timeout: pos_integer() | :unbounded | :infinity | nil,
          log_mode: :compact | :verbose,
          log_meta: :none | :full,
          events_mode: :compact | :full | :off,
          phase_names: map()
        }

  defstruct [
    :config_dir,
    :project_dir,
    :target_repos,
    :repo_groups,
    :prompts_file,
    :commit_messages_file,
    :progress_file,
    :log_dir,
    :llm_sdk,
    :model,
    :prompt_overrides,
    :allowed_tools,
    :permission_mode,
    :adapter_opts,
    :claude_opts,
    :codex_opts,
    :codex_thread_opts,
    :cli_confirmation,
    :timeout,
    :log_mode,
    :log_meta,
    :events_mode,
    :phase_names
  ]

  @spec load(String.t()) :: {:ok, t()} | {:error, term()}
  def load(config_path) do
    with {:ok, {config, config_dir}} <- read_config_file(config_path),
         {:ok, llm_sdk} <- normalize_llm_sdk(config[:llm] || %{}, config),
         {:ok, log_settings} <- normalize_log_settings(config),
         normalized <- build_config(config, config_dir, llm_sdk, log_settings),
         :ok <- validate(normalized) do
      {:ok, normalized}
    end
  end

  @spec with_overrides(t(), keyword()) :: t()
  def with_overrides(config, opts) do
    config
    |> maybe_override_project_dir(opts[:project_dir])
    |> apply_repo_overrides(opts[:repo_override])
    |> maybe_override_log_mode(opts[:log_mode])
    |> maybe_override_log_meta(opts[:log_meta])
    |> maybe_override_events_mode(opts[:events_mode])
    |> maybe_override_cli_confirmation(opts[:cli_confirmation])
    |> maybe_override_require_cli_confirmation(opts[:require_cli_confirmation])
  end

  @doc """
  Builds the LLM configuration map for a specific prompt by deep-merging
  root-level defaults with per-prompt overrides.
  """
  @spec llm_for_prompt(t(), map()) :: map()
  def llm_for_prompt(config, prompt) do
    prompt_repo_paths = resolve_prompt_repo_paths(config, prompt)
    cwd = List.first(prompt_repo_paths) || config.project_dir

    codex_thread_opts =
      enrich_codex_thread_opts(config.codex_thread_opts || %{}, prompt_repo_paths, cwd)

    base = %{
      sdk: config.llm_sdk,
      provider: config.llm_sdk,
      model: config.model,
      cwd: cwd,
      allowed_tools: config.allowed_tools,
      permission_mode: config.permission_mode,
      timeout: config.timeout,
      adapter_opts: config.adapter_opts || %{},
      claude_opts: config.claude_opts || %{},
      codex_opts: config.codex_opts || %{},
      codex_thread_opts: codex_thread_opts,
      cli_confirmation: config.cli_confirmation
    }

    override = Map.get(config.prompt_overrides || %{}, prompt.num, %{})
    merged = deep_merge(base, override)

    merged =
      Map.update(merged, :codex_thread_opts, %{}, fn opts ->
        enrich_codex_thread_opts(opts, prompt_repo_paths, merged[:cwd])
      end)

    sdk = resolve_merged_sdk(merged, base.sdk)

    merged
    |> Map.put(:sdk, sdk)
    |> Map.put(:provider, sdk)
    |> Map.update(:cli_confirmation, :warn, &normalize_cli_confirmation/1)
    |> Map.update(:permission_mode, nil, &normalize_permission_mode/1)
  end

  defp resolve_merged_sdk(merged, fallback) do
    case LLMFacade.normalize_provider(merged[:provider] || merged[:sdk]) do
      {:error, _} -> fallback
      other -> other
    end
  end

  defp resolve_prompt_repo_paths(config, prompt) do
    prompt
    |> resolve_target_repo_names(config)
    |> Enum.map(&resolve_repo_path(config, &1))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp resolve_target_repo_names(%{target_repos: repos}, config) when is_list(repos) do
    {resolved, _errors} = RepoTargets.expand(repos, config.repo_groups || %{})
    resolved
  end

  defp resolve_target_repo_names(_prompt, config) do
    case default_repo_path(config) do
      nil -> []
      _path -> [default_repo_name(config)]
    end
  end

  defp resolve_repo_path(config, repo_name) do
    case config.target_repos do
      repos when is_list(repos) ->
        case Enum.find(repos, &(&1.name == repo_name)) do
          %{path: path} -> path
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp default_repo_path(config) do
    case config.target_repos do
      repos when is_list(repos) -> find_default_repo_field(repos, :path)
      _ -> nil
    end
  end

  defp default_repo_name(config) do
    case config.target_repos do
      repos when is_list(repos) -> find_default_repo_field(repos, :name)
      _ -> nil
    end
  end

  defp find_default_repo_field(repos, field) do
    repo = Enum.find(repos, &(&1.default == true)) || List.first(repos)
    if repo, do: Map.get(repo, field)
  end

  defp enrich_codex_thread_opts(opts, prompt_repo_paths, cwd) when is_map(opts) do
    additional_directories =
      prompt_repo_paths
      |> Enum.reject(&(&1 == cwd))

    merged_dirs =
      opts
      |> Map.get(:additional_directories, [])
      |> normalize_additional_dirs()
      |> Kernel.++(additional_directories)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    Map.put(opts, :additional_directories, merged_dirs)
  end

  defp enrich_codex_thread_opts(opts, _prompt_repo_paths, _cwd), do: opts

  defp normalize_additional_dirs(dirs) when is_list(dirs), do: dirs
  defp normalize_additional_dirs(_), do: []

  defp normalize_llm_sdk(llm_section, config) do
    case LLMFacade.normalize_provider(
           llm_section[:provider] || llm_section[:sdk] || config[:llm_sdk] || config[:provider] ||
             config[:sdk]
         ) do
      {:error, reason} -> {:error, {:invalid_llm_sdk, reason}}
      sdk -> {:ok, sdk}
    end
  end

  defp normalize_log_settings(config) do
    with {:ok, log_mode} <- normalize_log_mode(config[:log_mode]),
         {:ok, log_meta} <- normalize_log_meta(config[:log_meta], log_mode),
         {:ok, events_mode} <- normalize_events_mode(config[:events_mode]) do
      {:ok, %{log_mode: log_mode, log_meta: log_meta, events_mode: events_mode}}
    end
  end

  defp build_config(config, config_dir, llm_sdk, log_settings) do
    llm_section = config[:llm] || %{}
    target_repos = normalize_target_repos(config[:target_repos], config_dir)

    prompt_overrides =
      normalize_prompt_overrides(
        coalesce([llm_section[:prompt_overrides], config[:prompt_overrides]], %{})
      )

    %__MODULE__{
      config_dir: config_dir,
      project_dir: normalize_path(config[:project_dir], config_dir),
      target_repos: target_repos,
      repo_groups: coalesce([config[:repo_groups]], %{}),
      prompts_file: normalize_path(config[:prompts_file], config_dir),
      commit_messages_file: normalize_path(config[:commit_messages_file], config_dir),
      progress_file: normalize_path(config[:progress_file], config_dir),
      log_dir: normalize_path(config[:log_dir], config_dir),
      llm_sdk: llm_sdk,
      model: coalesce([llm_section[:model], config[:model]], nil),
      prompt_overrides: prompt_overrides,
      allowed_tools: coalesce([llm_section[:allowed_tools], config[:allowed_tools]], nil),
      permission_mode:
        coalesce([llm_section[:permission_mode], config[:permission_mode]], nil)
        |> normalize_permission_mode(),
      adapter_opts: coalesce([llm_section[:adapter_opts], config[:adapter_opts]], %{}),
      claude_opts: coalesce([llm_section[:claude_opts], config[:claude_opts]], %{}),
      codex_opts: coalesce([llm_section[:codex_opts], config[:codex_opts]], %{}),
      codex_thread_opts:
        coalesce([llm_section[:codex_thread_opts], config[:codex_thread_opts]], %{}),
      cli_confirmation:
        coalesce([llm_section[:cli_confirmation], config[:cli_confirmation]], :warn)
        |> normalize_cli_confirmation(),
      timeout:
        coalesce([llm_section[:timeout], config[:timeout]], nil)
        |> normalize_timeout_value(),
      log_mode: log_settings.log_mode,
      log_meta: log_settings.log_meta,
      events_mode: log_settings.events_mode,
      phase_names: coalesce([config[:phase_names]], %{})
    }
  end

  defp coalesce(values, default) do
    Enum.find_value(values, default, fn value -> if value in [nil, ""], do: nil, else: value end)
  end

  defp read_config_file(config_path) do
    if File.exists?(config_path) do
      config_dir = Path.dirname(Path.expand(config_path))
      {config, _} = Code.eval_file(config_path)
      {:ok, {config, config_dir}}
    else
      {:error, {:config_not_found, config_path}}
    end
  end

  defp normalize_target_repos(nil, _config_dir), do: nil

  defp normalize_target_repos(repos, config_dir) when is_list(repos) do
    Enum.map(repos, fn repo ->
      %{
        name: repo[:name] || repo["name"],
        path: normalize_path(repo[:path] || repo["path"], config_dir),
        default: repo[:default] || repo["default"] || false
      }
    end)
  end

  defp normalize_target_repos(_other, _config_dir), do: nil

  defp normalize_path(nil, _config_dir), do: nil

  defp normalize_path(path, config_dir) when is_binary(path) do
    if Path.type(path) == :absolute do
      path
    else
      Path.join(config_dir, path)
    end
  end

  defp normalize_log_mode(nil), do: {:ok, :compact}
  defp normalize_log_mode(mode) when is_atom(mode), do: normalize_log_mode(Atom.to_string(mode))

  defp normalize_log_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "compact" -> {:ok, :compact}
      "verbose" -> {:ok, :verbose}
      other -> {:error, {:invalid_log_mode, other}}
    end
  end

  defp normalize_log_mode(mode), do: {:error, {:invalid_log_mode, mode}}

  defp normalize_log_meta(nil, _log_mode), do: {:ok, :none}

  defp normalize_log_meta(meta, _log_mode) when is_atom(meta),
    do: normalize_log_meta(Atom.to_string(meta), nil)

  defp normalize_log_meta(meta, _log_mode) when is_binary(meta) do
    case String.downcase(meta) do
      "none" -> {:ok, :none}
      "full" -> {:ok, :full}
      other -> {:error, {:invalid_log_meta, other}}
    end
  end

  defp normalize_log_meta(meta, _log_mode), do: {:error, {:invalid_log_meta, meta}}

  defp normalize_events_mode(nil), do: {:ok, :compact}

  defp normalize_events_mode(mode) when is_atom(mode),
    do: normalize_events_mode(Atom.to_string(mode))

  defp normalize_events_mode(mode) when is_binary(mode) do
    case String.downcase(mode) do
      "compact" -> {:ok, :compact}
      "full" -> {:ok, :full}
      "off" -> {:ok, :off}
      other -> {:error, {:invalid_events_mode, other}}
    end
  end

  defp normalize_events_mode(mode), do: {:error, {:invalid_events_mode, mode}}

  defp maybe_override_cli_confirmation(config, nil), do: config

  defp maybe_override_cli_confirmation(config, value) do
    %{config | cli_confirmation: normalize_cli_confirmation(value)}
  end

  defp maybe_override_require_cli_confirmation(config, nil), do: config

  # Backward-compatible CLI alias: --require-cli-confirmation implies :require.
  defp maybe_override_require_cli_confirmation(config, value) do
    if truthy?(value) do
      %{config | cli_confirmation: :require}
    else
      config
    end
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_), do: false

  defp normalize_cli_confirmation(value) when is_atom(value) do
    normalize_cli_confirmation(Atom.to_string(value))
  end

  defp normalize_cli_confirmation(value) when is_binary(value) do
    case value |> String.trim() |> String.downcase() do
      "off" -> :off
      "warn" -> :warn
      "require" -> :require
      _ -> :warn
    end
  end

  defp normalize_cli_confirmation(_), do: :warn

  defp normalize_prompt_overrides(nil), do: %{}

  defp normalize_prompt_overrides(overrides) when is_list(overrides) do
    overrides
    |> Enum.into(%{}, fn {k, v} -> {normalize_prompt_num(k), normalize_prompt_override(v)} end)
  end

  defp normalize_prompt_overrides(overrides) when is_map(overrides) do
    overrides
    |> Enum.into(%{}, fn {k, v} -> {normalize_prompt_num(k), normalize_prompt_override(v)} end)
  end

  defp normalize_prompt_overrides(_), do: %{}

  defp normalize_prompt_num(num) when is_integer(num) do
    num |> Integer.to_string() |> String.pad_leading(2, "0")
  end

  defp normalize_prompt_num(num) when is_binary(num) do
    trimmed = String.trim(num)

    if trimmed =~ ~r/^\d+$/ do
      trimmed |> String.to_integer() |> normalize_prompt_num()
    else
      trimmed
    end
  end

  defp normalize_prompt_num(other), do: inspect(other)

  defp normalize_prompt_override(nil), do: %{}

  defp normalize_prompt_override(kw) when is_list(kw),
    do: kw |> Enum.into(%{}) |> normalize_prompt_override()

  defp normalize_prompt_override(map) when is_map(map) do
    map =
      Enum.reduce(map, %{}, fn {k, v}, acc ->
        key =
          cond do
            is_atom(k) -> k
            is_binary(k) -> String.to_atom(k)
            true -> k
          end

        Map.put(acc, key, v)
      end)

    map =
      Map.update(map, :timeout, nil, fn timeout ->
        normalize_timeout_value(timeout)
      end)

    sdk =
      case LLMFacade.normalize_provider(map[:provider] || map[:sdk] || map[:llm_sdk]) do
        {:error, _} -> nil
        other -> other
      end

    if sdk do
      map
      |> Map.put(:sdk, sdk)
      |> Map.put(:provider, sdk)
      |> Map.delete(:llm_sdk)
    else
      map
    end
  end

  defp normalize_prompt_override(_), do: %{}

  defp normalize_permission_mode(nil), do: nil
  defp normalize_permission_mode(:bypass_permissions), do: :full_auto
  defp normalize_permission_mode("bypass_permissions"), do: :full_auto

  defp normalize_permission_mode(mode) do
    case PermissionMode.normalize(mode) do
      {:ok, normalized} -> normalized
      {:error, _reason} -> mode
    end
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp deep_merge(_left, right), do: right

  defp maybe_override_project_dir(config, nil), do: config

  defp maybe_override_project_dir(config, project_dir) do
    %{config | project_dir: project_dir}
  end

  defp apply_repo_overrides(config, nil), do: config
  defp apply_repo_overrides(config, []), do: config

  defp apply_repo_overrides(config, overrides) when is_list(overrides) do
    updated_repos =
      Enum.reduce(overrides, config.target_repos || [], fn override, repos ->
        apply_repo_override(override, repos)
      end)

    %{config | target_repos: updated_repos}
  end

  defp apply_repo_override(override, repos) do
    case String.split(override, ":", parts: 2) do
      [name, path] ->
        upsert_repo_override(repos, name, path)

      _ ->
        IO.puts(UI.yellow("WARNING: Invalid repo override format: #{override}"))
        IO.puts("Expected format: --repo-override NAME:PATH")
        repos
    end
  end

  defp upsert_repo_override(repos, name, path) do
    if Enum.any?(repos, &(&1.name == name)) do
      Enum.map(repos, &update_repo_path(&1, name, path))
    else
      repos ++ [%{name: name, path: path, default: false}]
    end
  end

  defp update_repo_path(%{name: name} = repo, name, path), do: %{repo | path: path}
  defp update_repo_path(repo, _name, _path), do: repo

  defp maybe_override_log_mode(config, nil), do: config

  defp maybe_override_log_mode(config, mode) do
    case normalize_log_mode(mode) do
      {:error, _} -> config
      {:ok, normalized} -> %{config | log_mode: normalized}
    end
  end

  defp maybe_override_log_meta(config, nil), do: config

  defp maybe_override_log_meta(config, meta) do
    case normalize_log_meta(meta, config.log_mode) do
      {:error, _} -> config
      {:ok, normalized} -> %{config | log_meta: normalized}
    end
  end

  defp maybe_override_events_mode(config, nil), do: config

  defp maybe_override_events_mode(config, mode) do
    case normalize_events_mode(mode) do
      {:error, _} -> config
      {:ok, normalized} -> %{config | events_mode: normalized}
    end
  end

  defp validate(config) do
    errors =
      []
      |> require_value(config.project_dir, :project_dir)
      |> require_value(config.prompts_file, :prompts_file)
      |> require_value(config.commit_messages_file, :commit_messages_file)
      |> require_value(config.progress_file, :progress_file)
      |> require_value(config.log_dir, :log_dir)
      |> require_value(config.model, :model)
      |> maybe_invalid_timeout(config.timeout)
      |> maybe_missing_path(config.project_dir, :project_dir)
      |> maybe_missing_path(config.prompts_file, :prompts_file)
      |> maybe_missing_path(config.commit_messages_file, :commit_messages_file)

    if errors == [] do
      :ok
    else
      {:error, errors}
    end
  end

  defp require_value(errors, value, key) when value in [nil, ""] do
    [{key, :missing_value} | errors]
  end

  defp require_value(errors, _value, _key), do: errors

  defp maybe_missing_path(errors, nil, _key), do: errors

  defp maybe_missing_path(errors, path, key) do
    if File.exists?(path) do
      errors
    else
      [{key, {:path_not_found, path}} | errors]
    end
  end

  defp maybe_invalid_timeout(errors, nil), do: errors

  defp maybe_invalid_timeout(errors, timeout) when timeout in [:unbounded, :infinity], do: errors

  defp maybe_invalid_timeout(errors, timeout)
       when is_integer(timeout) and timeout > 0,
       do: errors

  defp maybe_invalid_timeout(errors, timeout),
    do: [{:timeout, {:invalid_timeout, timeout}} | errors]

  defp normalize_timeout_value(nil), do: nil
  defp normalize_timeout_value(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_timeout_value(timeout) when timeout in [:unbounded, :infinity], do: timeout

  defp normalize_timeout_value(timeout) when is_binary(timeout) do
    case timeout |> String.trim() |> String.downcase() do
      "unbounded" -> :unbounded
      "infinity" -> :infinity
      "infinite" -> :infinity
      value -> normalize_numeric_timeout(value, timeout)
    end
  end

  defp normalize_timeout_value(timeout), do: timeout

  defp normalize_numeric_timeout(value, original) do
    case Integer.parse(value) do
      {parsed, ""} when parsed > 0 -> parsed
      _ -> original
    end
  end
end
