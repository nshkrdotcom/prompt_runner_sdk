defmodule PromptRunner.Plan do
  @moduledoc """
  Fully resolved execution plan used by the PromptRunner runtime.
  """

  alias PromptRunner.Committer.GitCommitter
  alias PromptRunner.Committer.NoopCommitter
  alias PromptRunner.Config
  alias PromptRunner.LLMFacade
  alias PromptRunner.Paths
  alias PromptRunner.PermissionMode
  alias PromptRunner.Profile
  alias PromptRunner.Prompt
  alias PromptRunner.RecoveryConfig
  alias PromptRunner.RunSpec
  alias PromptRunner.RuntimeStore.FileStore
  alias PromptRunner.RuntimeStore.MemoryStore
  alias PromptRunner.RuntimeStore.NoopStore
  alias PromptRunner.Source.Result

  @type callbacks :: %{
          optional(:on_event) => (map() -> term()) | nil,
          optional(:on_prompt_started) => (map() -> term()) | nil,
          optional(:on_prompt_completed) => (map() -> term()) | nil,
          optional(:on_prompt_failed) => (map() -> term()) | nil,
          optional(:on_run_completed) => (map() -> term()) | nil
        }

  @type t :: %__MODULE__{
          config: Config.t(),
          options: map(),
          prompts: [Prompt.t()],
          commit_messages: %{optional({String.t(), String.t() | nil}) => String.t()},
          source: module(),
          source_input: term(),
          source_root: String.t() | nil,
          interface: :api | :cli | :legacy,
          input_type: RunSpec.input_type(),
          state_dir: String.t() | nil,
          runtime_store: {module(), term()},
          committer: {module(), keyword()},
          callbacks: callbacks()
        }

  defstruct [
    :config,
    :options,
    :prompts,
    :commit_messages,
    :source,
    :source_input,
    :source_root,
    :interface,
    :input_type,
    :state_dir,
    :runtime_store,
    :committer,
    :callbacks
  ]

  @spec build(RunSpec.t()) :: {:ok, t()} | {:error, term()}
  def build(%RunSpec{} = run_spec) do
    with {:ok, %Result{} = result} <- run_spec.source.load(run_spec.input, run_spec.opts),
         merged_opts <- merged_opts(run_spec, result),
         {:ok, config} <- build_config(run_spec, result, merged_opts),
         {:ok, runtime_store} <- build_runtime_store(run_spec, config),
         {:ok, committer} <- build_committer(run_spec) do
      {:ok, build_plan(run_spec, result, config, merged_opts, runtime_store, committer)}
    end
  end

  @spec with_overrides(t(), keyword()) :: t()
  def with_overrides(%__MODULE__{} = plan, opts) do
    %{plan | config: Config.with_overrides(plan.config, opts)}
  end

  defp build_plan(run_spec, result, config, options, runtime_store, committer) do
    %__MODULE__{
      config: config,
      options: options,
      prompts: result.prompts,
      commit_messages: result.commit_messages,
      source: run_spec.source,
      source_input: run_spec.input,
      source_root: Paths.resolve(result.source_root),
      interface: run_spec.interface,
      input_type: run_spec.input_type,
      state_dir: runtime_state_dir(run_spec, result),
      runtime_store: runtime_store,
      committer: committer,
      callbacks: callback_map(run_spec.opts)
    }
  end

  defp build_config(
         %RunSpec{interface: :legacy},
         %Result{legacy_config: %Config{} = config},
         _merged_opts
       ) do
    {:ok, config}
  end

  defp build_config(%RunSpec{} = _run_spec, %Result{} = result, opts) do
    model = value_from(opts, [:model], "claude-sonnet-4-6")

    with {:ok, llm_sdk} <- resolve_llm_sdk(opts, model) do
      config = resolved_config(opts, result, llm_sdk, model)

      with :ok <- validate_permission_mode(config.permission_mode, llm_sdk) do
        {:ok, config}
      end
    end
  end

  defp merged_opts(run_spec, result) do
    defaults()
    |> deep_merge(env_overrides())
    |> deep_merge(global_config(result))
    |> deep_merge(local_config(result.source_root))
    |> deep_merge(result.metadata[:options] || result.metadata["options"] || %{})
    |> deep_merge(Map.new(run_spec.opts))
    |> normalize_options()
  end

  defp resolve_llm_sdk(opts, model) do
    provider = opts[:provider] || opts[:sdk] || infer_provider(model)

    case LLMFacade.normalize_provider(provider) do
      {:error, reason} -> {:error, reason}
      sdk -> {:ok, sdk}
    end
  end

  defp resolved_config(opts, result, llm_sdk, model) do
    config_dir = Paths.resolve(result.source_root || File.cwd!())
    target_repos = resolve_target_repos(opts, result, config_dir)
    project_dir = default_project_dir(target_repos, result, config_dir)
    {log_mode, log_meta, events_mode, tool_output} = normalize_display(opts)

    %Config{
      config_dir: config_dir,
      project_dir: project_dir,
      target_repos: target_repos,
      repo_groups: Map.get(result, :repo_groups, %{}),
      prompts_file: nil,
      commit_messages_file: nil,
      progress_file: nil,
      log_dir: nil,
      llm_sdk: llm_sdk,
      model: model,
      prompt_overrides: normalize_prompt_overrides(opts[:prompt_overrides]),
      allowed_tools: opts[:allowed_tools],
      permission_mode: PermissionMode.normalize(opts[:permission_mode], llm_sdk),
      adapter_opts: opts[:adapter_opts] || %{},
      claude_opts: opts[:claude_opts] || %{},
      codex_opts: opts[:codex_opts] || %{},
      codex_thread_opts: opts[:codex_thread_opts] || %{},
      cli_confirmation: opts[:cli_confirmation] || :warn,
      timeout: opts[:timeout],
      log_mode: log_mode,
      log_meta: log_meta,
      events_mode: events_mode,
      tool_output: tool_output,
      phase_names: Map.get(result, :phase_names, %{})
    }
  end

  defp validate_permission_mode(nil, _provider), do: :ok
  defp validate_permission_mode(mode, :simulated), do: validate_simulated_permission_mode(mode)

  defp validate_permission_mode(mode, provider) do
    case ASM.Permission.normalize(provider, mode) do
      {:ok, _normalized} ->
        :ok

      {:error, _reason} ->
        {:error, {:permission_mode, {:invalid_permission_mode, provider, mode}}}
    end
  end

  defp validate_simulated_permission_mode(mode) do
    if PermissionMode.normalize(mode, :simulated) in PermissionMode.normalized_modes() do
      :ok
    else
      {:error, {:permission_mode, {:invalid_permission_mode, :simulated, mode}}}
    end
  end

  defp build_runtime_store(%RunSpec{} = run_spec, %Config{} = config) do
    module = resolve_runtime_store(run_spec)

    case module do
      FileStore ->
        state_dir =
          Paths.resolve(run_spec.opts[:state_dir], config.config_dir) ||
            Path.join(config.config_dir || File.cwd!(), ".prompt_runner")

        runtime_config = %{
          state_dir: state_dir,
          progress_file: config.progress_file || Path.join(state_dir, "progress.log"),
          log_dir: config.log_dir || Path.join(state_dir, "logs")
        }

        FileStore.setup(%{config: config, state_dir: state_dir, runtime_config: runtime_config})
        |> wrap_store(FileStore)

      MemoryStore ->
        MemoryStore.setup(%{}) |> wrap_store(MemoryStore)

      NoopStore ->
        NoopStore.setup(%{}) |> wrap_store(NoopStore)

      module when is_atom(module) ->
        module.setup(%{config: config}) |> wrap_store(module)
    end
  end

  defp wrap_store({:ok, state}, module), do: {:ok, {module, state}}
  defp wrap_store(error, _module), do: error

  defp build_committer(%RunSpec{} = run_spec) do
    {:ok, {resolve_committer(run_spec), []}}
  end

  defp callback_map(opts) do
    %{
      on_event: opts[:on_event],
      on_prompt_started: opts[:on_prompt_started],
      on_prompt_completed: opts[:on_prompt_completed],
      on_prompt_failed: opts[:on_prompt_failed],
      on_run_completed: opts[:on_run_completed]
    }
  end

  defp runtime_state_dir(%RunSpec{interface: :cli}, %Result{source_root: root})
       when is_binary(root),
       do: root |> Paths.resolve() |> Path.join(".prompt_runner")

  defp runtime_state_dir(%RunSpec{input_type: :packet}, %Result{source_root: root})
       when is_binary(root),
       do: root |> Paths.resolve() |> Path.join(".prompt_runner")

  defp runtime_state_dir(%RunSpec{interface: :legacy}, %Result{legacy_config: %Config{} = config}) do
    Path.dirname(config.progress_file || config.config_dir)
  end

  defp runtime_state_dir(_, _), do: nil

  defp resolve_target_repos(opts, %Result{target_repos: target_repos}, config_dir)
       when is_list(target_repos) and target_repos != [] do
    explicit_targets = normalize_target_opts(opts, config_dir)

    if explicit_targets == [] do
      normalize_target_repos(target_repos, config_dir)
    else
      explicit_targets
    end
  end

  defp resolve_target_repos(opts, _result, config_dir) do
    case normalize_target_opts(opts, config_dir) do
      [] -> nil
      repos -> repos
    end
  end

  defp normalize_target_opts(opts, config_dir) do
    opts
    |> collect_targets()
    |> Enum.with_index()
    |> Enum.map(fn {value, index} ->
      case String.split(value, ":", parts: 2) do
        [single] ->
          %{
            name: if(index == 0, do: "default", else: "target_#{index + 1}"),
            path: Paths.resolve(single, config_dir),
            default: index == 0
          }

        [name, path] ->
          %{name: name, path: Paths.resolve(path, config_dir), default: index == 0}
      end
    end)
  end

  defp normalize_target_repos(repos, config_dir) do
    Enum.map(repos, fn repo ->
      %{
        name: repo[:name] || repo["name"],
        path: Paths.resolve(repo[:path] || repo["path"], config_dir),
        default: repo[:default] || repo["default"] || false
      }
    end)
  end

  defp collect_targets(opts) do
    []
    |> Kernel.++(List.wrap(opts[:target]))
    |> Kernel.++(
      case opts[:targets] do
        map when is_map(map) ->
          Enum.map(map, fn {name, path} -> "#{name}:#{path}" end)

        list when is_list(list) ->
          Enum.map(list, fn
            {name, path} -> "#{name}:#{path}"
            value -> value
          end)

        value when is_binary(value) ->
          [value]

        _ ->
          []
      end
    )
    |> Enum.reject(&is_nil/1)
  end

  defp default_project_dir(repos, _result, _fallback) when is_list(repos) and repos != [] do
    repos
    |> Enum.find(&(&1.default == true))
    |> Kernel.||(List.first(repos))
    |> Map.fetch!(:path)
  end

  defp default_project_dir(_repos, %Result{project_dir: project_dir}, fallback),
    do: Paths.resolve(project_dir, fallback) || fallback

  defp normalize_display(opts) do
    {
      normalize_atom_option(opts[:log_mode], :compact),
      normalize_atom_option(opts[:log_meta], :none),
      normalize_atom_option(opts[:events_mode], :compact),
      normalize_atom_option(opts[:tool_output], :summary)
    }
  end

  defp normalize_atom_option(nil, default), do: default
  defp normalize_atom_option(value, _default) when is_atom(value), do: value
  defp normalize_atom_option(value, _default) when is_binary(value), do: String.to_atom(value)
  defp normalize_atom_option(_value, default), do: default

  defp normalize_prompt_overrides(overrides) when is_map(overrides), do: overrides
  defp normalize_prompt_overrides(nil), do: %{}
  defp normalize_prompt_overrides(_), do: %{}

  defp resolve_runtime_store(%RunSpec{input_type: :packet, opts: opts}) do
    cond do
      truthy?(opts[:no_state]) -> NoopStore
      opts[:runtime_store] in [:file, "file"] -> FileStore
      opts[:runtime_store] in [:memory, "memory"] -> MemoryStore
      opts[:runtime_store] in [:noop, "noop"] -> NoopStore
      is_atom(opts[:runtime_store]) and not is_nil(opts[:runtime_store]) -> opts[:runtime_store]
      true -> FileStore
    end
  end

  defp resolve_runtime_store(%RunSpec{interface: interface, opts: opts}) do
    cond do
      truthy?(opts[:no_state]) -> NoopStore
      opts[:runtime_store] in [:file, "file"] -> FileStore
      opts[:runtime_store] in [:memory, "memory"] -> MemoryStore
      opts[:runtime_store] in [:noop, "noop"] -> NoopStore
      is_atom(opts[:runtime_store]) and not is_nil(opts[:runtime_store]) -> opts[:runtime_store]
      interface in [:cli, :legacy] -> FileStore
      true -> MemoryStore
    end
  end

  defp resolve_committer(%RunSpec{interface: interface, input_type: input_type, opts: opts}) do
    opts[:committer]
    |> normalize_committer()
    |> default_committer(interface, input_type)
  end

  defp normalize_committer(nil), do: nil
  defp normalize_committer(:git), do: GitCommitter
  defp normalize_committer("git"), do: GitCommitter
  defp normalize_committer(:noop), do: NoopCommitter
  defp normalize_committer("noop"), do: NoopCommitter
  defp normalize_committer(module) when is_atom(module), do: module
  defp normalize_committer(_), do: :default

  defp default_committer(nil, _interface, :packet), do: GitCommitter

  defp default_committer(nil, interface, _input_type) when interface in [:cli, :legacy],
    do: GitCommitter

  defp default_committer(nil, _interface, _input_type), do: NoopCommitter
  defp default_committer(:default, _interface, :packet), do: GitCommitter

  defp default_committer(:default, interface, _input_type) when interface in [:cli, :legacy],
    do: GitCommitter

  defp default_committer(:default, _interface, _input_type), do: NoopCommitter
  defp default_committer(module, _interface, _input_type), do: module

  defp defaults, do: %{}

  defp env_overrides do
    %{}
    |> maybe_put(:model, System.get_env("PROMPT_RUNNER_MODEL"))
    |> maybe_put(:provider, System.get_env("PROMPT_RUNNER_PROVIDER"))
  end

  defp global_config(%Result{metadata: metadata}) do
    case metadata[:packet] || metadata["packet"] do
      nil -> Profile.global_defaults()
      _packet -> %{}
    end
  end

  defp local_config(nil), do: %{}

  defp local_config(dir) do
    config_path = Path.join(dir, "runner_config.exs")

    if File.exists?(config_path) and not File.exists?(Path.join(dir, "prompts.txt")) do
      optional_config(config_path)
    else
      %{}
    end
  end

  defp optional_config(path) do
    if File.exists?(path) do
      {config, _binding} = Code.eval_file(path)
      if is_map(config), do: config, else: %{}
    else
      %{}
    end
  rescue
    _ -> %{}
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp infer_provider(model) when is_binary(model) do
    cond do
      String.contains?(String.downcase(model), "gpt") -> :codex
      String.contains?(String.downcase(model), "amp") -> :amp
      true -> :claude
    end
  end

  defp infer_provider(_), do: :claude

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_), do: false

  defp value_from(map, keys, default) do
    Enum.find_value(keys, default, fn key ->
      case Map.get(map, key) do
        nil -> nil
        "" -> nil
        value -> value
      end
    end)
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _k, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp deep_merge(_left, right), do: right

  @option_keys %{
    "provider" => :provider,
    "sdk" => :sdk,
    "model" => :model,
    "reasoning_effort" => :reasoning_effort,
    "permission_mode" => :permission_mode,
    "allowed_tools" => :allowed_tools,
    "adapter_opts" => :adapter_opts,
    "claude_opts" => :claude_opts,
    "codex_opts" => :codex_opts,
    "codex_thread_opts" => :codex_thread_opts,
    "gemini_opts" => :gemini_opts,
    "amp_opts" => :amp_opts,
    "system_prompt" => :system_prompt,
    "append_system_prompt" => :append_system_prompt,
    "max_turns" => :max_turns,
    "cli_confirmation" => :cli_confirmation,
    "timeout" => :timeout,
    "log_mode" => :log_mode,
    "log_meta" => :log_meta,
    "events_mode" => :events_mode,
    "tool_output" => :tool_output,
    "recovery" => :recovery,
    "prompt_overrides" => :prompt_overrides,
    "target" => :target,
    "targets" => :targets,
    "project_dir" => :project_dir,
    "state_dir" => :state_dir,
    "no_state" => :no_state,
    "runtime_store" => :runtime_store,
    "committer" => :committer,
    "all" => :all,
    "phase" => :phase,
    "continue" => :continue,
    "run" => :run,
    "dry_run" => :dry_run,
    "no_commit" => :no_commit
  }

  defp normalize_options(map) when is_map(map) do
    Enum.reduce(map, %{}, fn {key, value}, acc ->
      normalized_key = normalize_option_key(key)
      Map.put(acc, normalized_key, normalize_option_value(normalized_key, value))
    end)
  end

  defp normalize_option_key(key) when is_atom(key), do: key
  defp normalize_option_key(key) when is_binary(key), do: Map.get(@option_keys, key, key)
  defp normalize_option_key(key), do: key

  defp normalize_option_value(:prompt_overrides, overrides) when is_map(overrides) do
    Map.new(overrides, fn {prompt_id, override} ->
      {to_string(prompt_id), normalize_options(override)}
    end)
  end

  defp normalize_option_value(key, value)
       when key in [
              :adapter_opts,
              :claude_opts,
              :codex_opts,
              :codex_thread_opts,
              :gemini_opts,
              :amp_opts
            ] and
              is_map(value) do
    stringify_keys(value)
  end

  defp normalize_option_value(:recovery, value) when is_map(value) do
    RecoveryConfig.normalize(%{"recovery" => value})
  end

  defp normalize_option_value(_key, value), do: value

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_map(value), do: stringify_keys(value), else: value)}
    end)
  end
end
