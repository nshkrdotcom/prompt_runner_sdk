defmodule PromptRunner.Config do
  @moduledoc """
  Loads and normalizes configuration for the prompt runner.
  """

  alias PromptRunner.LLM
  alias PromptRunner.LLMFacade
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
          claude_opts: map(),
          codex_opts: map(),
          codex_thread_opts: map(),
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
    :claude_opts,
    :codex_opts,
    :codex_thread_opts,
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
  end

  @spec llm_for_prompt(t(), map()) :: map()
  def llm_for_prompt(config, prompt) do
    base = %{
      sdk: config.llm_sdk,
      model: config.model,
      cwd: config.project_dir,
      allowed_tools: config.allowed_tools,
      permission_mode: config.permission_mode,
      claude_opts: config.claude_opts || %{},
      codex_opts: config.codex_opts || %{},
      codex_thread_opts: config.codex_thread_opts || %{}
    }

    override = Map.get(config.prompt_overrides || %{}, prompt.num, %{})
    merged = deep_merge(base, override)

    sdk =
      case LLMFacade.normalize_sdk(merged[:sdk]) do
        {:error, _} -> base.sdk
        other -> other
      end

    %{merged | sdk: sdk}
  end

  defp normalize_llm_sdk(llm_section, config) do
    case LLMFacade.normalize_sdk(llm_section[:sdk] || config[:llm_sdk] || config[:sdk]) do
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
      allowed_tools: config[:allowed_tools],
      permission_mode: config[:permission_mode],
      claude_opts: coalesce([llm_section[:claude_opts], config[:claude_opts]], %{}),
      codex_opts: coalesce([llm_section[:codex_opts], config[:codex_opts]], %{}),
      codex_thread_opts:
        coalesce([llm_section[:codex_thread_opts], config[:codex_thread_opts]], %{}),
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

    sdk =
      case LLMFacade.normalize_sdk(map[:sdk] || map[:llm_sdk] || map[:provider]) do
        {:error, _} -> nil
        other -> other
      end

    if sdk do
      map
      |> Map.put(:sdk, sdk)
      |> Map.delete(:llm_sdk)
      |> Map.delete(:provider)
    else
      map
    end
  end

  defp normalize_prompt_override(_), do: %{}

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
end
