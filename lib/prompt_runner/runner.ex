defmodule PromptRunner.Runner do
  @moduledoc false

  alias AgentSessionManager.Rendering
  alias AgentSessionManager.Rendering.Renderers.{CompactRenderer, VerboseRenderer}
  alias AgentSessionManager.Rendering.Sinks.{CallbackSink, FileSink, JSONLSink, TTYSink}
  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Git
  alias PromptRunner.Progress
  alias PromptRunner.Prompts
  alias PromptRunner.RepoTargets
  alias PromptRunner.UI
  alias PromptRunner.Validator

  @prompt_preview_lines 10

  @spec run(Config.t(), keyword(), list()) :: :ok | {:error, term()}
  def run(config, opts, remaining) do
    config = Config.with_overrides(config, opts)

    cond do
      opts[:validate] ->
        Validator.validate_all(config)

      opts[:list] ->
        list_prompts(config)

      opts[:dry_run] ->
        with {:ok, targets} <- build_targets(config, opts, remaining) do
          Enum.each(targets, &dry_run_prompt(config, &1, opts[:no_commit] || false))
          :ok
        end

      opts[:run] ->
        with {:ok, targets} <- build_targets(config, opts, remaining) do
          run_targets(config, targets, opts[:no_commit] || false)
        end

      true ->
        {:error, :no_command}
    end
  end

  defp run_targets(config, targets, skip_commit) do
    Enum.reduce_while(targets, :ok, fn num, _acc ->
      case run_prompt(config, num, skip_commit) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_targets(config, opts, remaining) do
    cond do
      remaining != [] ->
        {:ok, [hd(remaining)]}

      opts[:phase] ->
        {:ok, Prompts.phase_nums(config, opts[:phase])}

      opts[:continue] ->
        targets =
          case Progress.last_completed(config) do
            nil ->
              Prompts.nums(config)

            last ->
              next =
                last
                |> String.to_integer()
                |> Kernel.+(1)
                |> Integer.to_string()
                |> String.pad_leading(2, "0")

              Prompts.nums(config) |> Enum.filter(&(&1 >= next))
          end

        {:ok, targets}

      opts[:all] ->
        {:ok, Prompts.nums(config)}

      true ->
        {:error, :no_target}
    end
  end

  defp list_prompts(config) do
    IO.puts("")
    IO.puts(UI.bold("Implementation Prompts"))
    IO.puts(UI.cyan("Config: #{config.config_dir}"))
    IO.puts(UI.cyan("Project: #{config.project_dir}"))
    IO.puts("")

    prompts = Prompts.list(config)
    statuses = Progress.statuses(config)

    {completed, total, _} =
      Enum.reduce(prompts, {0, 0, nil}, fn prompt, {c, t, last_phase} ->
        last_phase = maybe_print_phase_header(config, prompt, last_phase)
        {line, completed_inc} = format_prompt_line(config, statuses, prompt)
        IO.puts(line)
        {c + completed_inc, t + 1, last_phase}
      end)

    IO.puts("")
    IO.puts(UI.bold("Progress:"))
    IO.puts("#{completed}/#{total} completed")
    IO.puts("")
  end

  defp maybe_print_phase_header(config, prompt, last_phase) do
    if prompt.phase != last_phase do
      if last_phase != nil, do: IO.puts("")
      phase_name = Map.get(config.phase_names, prompt.phase, "Unknown")
      IO.puts(UI.green("Phase #{prompt.phase}: #{phase_name}"))
    end

    prompt.phase
  end

  defp format_prompt_line(config, statuses, prompt) do
    prompt_status = Progress.status(statuses, prompt.num)

    status_label =
      case prompt_status.status do
        "completed" -> UI.green("[x]")
        "failed" -> UI.red("[!]")
        _ -> "[ ]"
      end

    completed_inc = if Progress.completed?(statuses, prompt.num), do: 1, else: 0

    prompt_path = Path.join(config.config_dir, prompt.file)
    missing = if File.exists?(prompt_path), do: "", else: " #{UI.red("(missing)")}"

    commit_suffix = format_commit_suffix(prompt_status.commit)
    repos_suffix = format_repos_suffix(prompt.target_repos)

    line =
      "  #{status_label} #{prompt.num} - #{prompt.name} (#{prompt.sp} SP)#{repos_suffix}#{commit_suffix}#{missing}"

    {line, completed_inc}
  end

  defp dry_run_prompt(config, num, skip_commit) do
    case Prompts.get(config, num) do
      nil ->
        IO.puts(UI.red("ERROR: Prompt #{num} not found"))

      prompt ->
        prompt_path = Path.join(config.config_dir, prompt.file)
        llm = Config.llm_for_prompt(config, prompt)

        IO.puts("")
        IO.puts(UI.bold("[DRY RUN] Prompt #{num}: #{prompt.name}"))
        IO.puts("")

        print_prompt_file_info(prompt_path)
        print_execution_info(config, prompt, llm)
        print_git_commit_info(config, prompt, skip_commit)

        IO.puts("")
    end
  end

  defp print_prompt_file_info(prompt_path) do
    IO.puts(UI.yellow("1. Prompt file:"))

    if File.exists?(prompt_path) do
      stat = File.stat!(prompt_path)
      lines = prompt_path |> File.read!() |> String.split("\n") |> length()
      IO.puts("   #{prompt_path}")
      IO.puts("   #{lines} lines, #{stat.size} bytes")
    else
      IO.puts("   #{UI.red("NOT FOUND:")} #{prompt_path}")
    end

    IO.puts("")
  end

  defp print_execution_info(config, prompt, llm) do
    IO.puts(UI.yellow("2. Execution:"))
    IO.puts("   LLM provider: #{llm.sdk}")
    IO.puts("   - model: #{llm.model}")

    if llm.sdk == :codex do
      case configured_codex_reasoning(llm) do
        nil -> :ok
        reasoning -> IO.puts("   - reasoning_effort: #{reasoning}")
      end
    end

    IO.puts("   - cwd: #{llm.cwd}")

    if is_list(llm.allowed_tools) do
      IO.puts("   - allowed_tools: #{Enum.join(llm.allowed_tools, ", ")}")
    end

    if llm.permission_mode != nil do
      IO.puts("   - permission_mode: #{llm.permission_mode}")
    end

    if is_map(llm[:adapter_opts]) and map_size(llm.adapter_opts) > 0 do
      IO.puts("   - adapter_opts: #{inspect(llm.adapter_opts)}")
    end

    if llm.sdk == :codex and is_map(llm[:codex_thread_opts]) and
         map_size(llm.codex_thread_opts) > 0 do
      IO.puts("   - codex_thread_opts: #{inspect(llm.codex_thread_opts)}")
    end

    print_target_repos(config, prompt)
    IO.puts("")
  end

  defp print_target_repos(config, prompt) do
    case prompt.target_repos do
      nil ->
        IO.puts("   - target_repo: #{config.project_dir}")

      repos when is_list(repos) ->
        IO.puts("   - target_repos: #{Enum.join(repos, ", ")}")

        {resolved_repos, errors} = RepoTargets.expand(repos, config.repo_groups)

        Enum.each(errors, fn error ->
          IO.puts("     - #{UI.red("ERR")} #{RepoTargets.format_error(error)}")
        end)

        Enum.each(resolved_repos, fn repo_name ->
          repo_path = get_repo_path(config, repo_name)
          IO.puts("     - #{repo_name}: #{repo_path || "(not configured)"}")
        end)
    end
  end

  defp print_git_commit_info(config, prompt, skip_commit) do
    IO.puts(UI.yellow("3. Git commit:"))

    if skip_commit do
      IO.puts("   SKIPPED (--no-commit)")
    else
      print_commit_messages(config, prompt)
    end

    IO.puts("")
  end

  defp print_commit_messages(config, prompt) do
    case prompt.target_repos do
      nil ->
        print_single_commit_message(config, prompt)

      repos when is_list(repos) ->
        {resolved_repos, errors} = RepoTargets.expand(repos, config.repo_groups)

        Enum.each(errors, fn error ->
          IO.puts("   #{UI.red("ERR")} #{RepoTargets.format_error(error)}")
        end)

        Enum.each(resolved_repos, &print_repo_commit_message(config, prompt, &1))
    end
  end

  defp print_single_commit_message(config, prompt) do
    case CommitMessages.get_message(config, prompt.num) do
      nil ->
        IO.puts("   #{UI.red("COMMIT MESSAGE NOT FOUND")} for #{prompt.num}")

      msg ->
        show_commit_message_preview(msg, nil)
    end
  end

  defp print_repo_commit_message(config, prompt, repo_name) do
    IO.puts("   #{UI.bold(repo_name <> ":")}")

    case CommitMessages.get_message(config, prompt.num, repo_name) do
      nil ->
        IO.puts("   #{UI.red("COMMIT MESSAGE NOT FOUND")} for #{prompt.num}:#{repo_name}")

      msg ->
        show_commit_message_preview(msg, "   ")
    end

    IO.puts("")
  end

  defp show_commit_message_preview(msg, indent) do
    prefix = indent || "   "

    msg
    |> String.split("\n")
    |> Enum.take(10)
    |> Enum.each(&IO.puts("#{prefix}#{&1}"))

    total_lines = msg |> String.split("\n") |> length()

    if total_lines > 10 do
      IO.puts("#{prefix}... (#{total_lines - 10} more lines)")
    end
  end

  defp run_prompt(config, num, skip_commit) do
    case Prompts.get(config, num) do
      nil ->
        {:error, {:prompt_not_found, num}}

      prompt ->
        prompt_path = Path.join(config.config_dir, prompt.file)

        if File.exists?(prompt_path) do
          llm = Config.llm_for_prompt(config, prompt)

          case preflight_llm_dependency(llm) do
            {:ok, sdk_info} ->
              IO.puts("")
              IO.puts(UI.blue(String.duplicate("=", 60)))
              IO.puts(UI.bold("Prompt #{num}: #{prompt.name}"))
              IO.puts(UI.blue(String.duplicate("=", 60)))
              IO.puts("")
              IO.puts("Prompt: #{prompt_path}")
              IO.puts("Project: #{llm.cwd}")
              IO.puts("LLM: #{llm_summary(llm)}")
              maybe_print_sdk_preflight(sdk_info)
              IO.puts("")

              File.mkdir_p!(config.log_dir)
              timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
              log_file = Path.join(config.log_dir, "prompt-#{num}-#{timestamp}.log")
              events_file = Path.join(config.log_dir, "prompt-#{num}-#{timestamp}.events.jsonl")

              IO.puts("Log: #{log_file}")
              IO.puts("Events: #{events_file}")
              IO.puts("")

              prompt_content = File.read!(prompt_path)

              IO.puts(UI.yellow("Prompt preview (first #{@prompt_preview_lines} lines):"))

              prompt_content
              |> String.split("\n")
              |> Enum.take(@prompt_preview_lines)
              |> Enum.each(&IO.puts("  #{&1}"))

              IO.puts("  ...")
              IO.puts("")
              IO.puts(UI.yellow("Starting #{llm.sdk} session..."))
              IO.puts("")

              {:ok, log_io} = File.open(log_file, [:write, :utf8])

              llm_module().start_stream(llm, prompt_content)
              |> handle_stream_result(
                config,
                prompt,
                prompt_path,
                llm,
                {log_io, events_file},
                skip_commit
              )

            {:error, reason} ->
              return_error(config, num, reason)
          end
        else
          return_error(config, num, {:prompt_file_not_found, prompt_path})
        end
    end
  end

  defp handle_stream_result(
         {:ok, stream, close_llm, llm_meta},
         config,
         prompt,
         prompt_path,
         llm,
         {log_io, events_file},
         skip_commit
       ) do
    write_session_header(log_io, config, llm, llm_meta, prompt_path)
    initialize_cli_confirmation_tracking(llm, config, log_io)

    renderer = renderer_for_config(config)
    sinks = build_sinks(config, log_io, events_file, llm)

    render_result = safe_render_stream(stream, renderer, sinks)
    callback_result = Process.get(:prompt_runner_stream_result, :ok)
    Process.delete(:prompt_runner_stream_result)
    result = resolve_stream_result(render_result, callback_result)
    result = maybe_finalize_cli_confirmation(result, llm, config, log_io)

    Process.delete(:prompt_runner_cli_confirmation_printed)
    Process.delete(:prompt_runner_cli_confirmation_audit)

    IO.puts("")
    finalize_stream_result(result, config, prompt, llm, skip_commit)
  after
    close_llm.()
    File.close(log_io)
  end

  defp handle_stream_result(
         {:error, reason},
         config,
         prompt,
         _prompt_path,
         _llm,
         {log_io, _events_file},
         _skip_commit
       ) do
    File.close(log_io)
    return_error(config, prompt.num, {:start_failed, reason})
  end

  defp return_error(config, num, reason) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    Progress.mark_failed(config, num)
    {:error, reason}
  end

  defp safe_render_stream(stream, renderer, sinks) do
    Rendering.stream(stream, renderer: renderer, sinks: sinks)
  rescue
    exception ->
      {:error, {:stream_failed, Exception.message(exception)}}
  catch
    kind, reason ->
      {:error, {:stream_failed, "#{kind}: #{inspect(reason)}"}}
  end

  defp resolve_stream_result(:ok, callback_result), do: callback_result
  defp resolve_stream_result({:error, reason}, _callback_result), do: {:error, reason}

  defp renderer_for_config(config) do
    case config.log_mode do
      :verbose -> {VerboseRenderer, []}
      _ -> {CompactRenderer, []}
    end
  end

  defp build_sinks(config, log_io, events_file, llm) do
    sinks = [
      {TTYSink, []},
      {FileSink, [io: log_io]},
      {CallbackSink,
       [callback: fn event, iodata -> stream_tracking_callback(event, iodata, llm, log_io) end]}
    ]

    if config.events_mode != :off do
      sinks ++ [{JSONLSink, [path: events_file, mode: config.events_mode]}]
    else
      sinks
    end
  end

  defp stream_tracking_callback(event, _iodata, llm, log_io) do
    maybe_print_cli_confirmation(event, llm, log_io)
    error_tracking_callback(event)
  end

  defp error_tracking_callback(event) do
    case event.type do
      type when type in [:error_occurred, :run_failed] ->
        msg = get_in(event, [:data, :error_message]) || "unknown error"
        Process.put(:prompt_runner_stream_result, {:error, msg})

      _ ->
        :ok
    end
  end

  defp maybe_print_cli_confirmation(%{type: :run_started} = event, %{sdk: :codex}, log_io) do
    case extract_codex_cli_confirmation(event) do
      %{model: model, reasoning_effort: reasoning_effort} = confirmation
      when is_binary(model) and model != "" and not is_nil(reasoning_effort) ->
        IO.puts("\nLLM confirmed (codex_cli): model=#{model} reasoning=#{reasoning_effort}")

        audit =
          Process.get(:prompt_runner_cli_confirmation_audit, %{})
          |> Map.put(:confirmed_model, model)
          |> Map.put(:confirmed_reasoning_effort, to_string(reasoning_effort))
          |> Map.put(:confirmation_source, confirmation.source || "codex_cli.run_started")

        Process.put(:prompt_runner_cli_confirmation_printed, true)
        Process.put(:prompt_runner_cli_confirmation_audit, audit)

        IO.binwrite(
          log_io,
          "LLM_AUDIT_CONFIRMED source=#{audit.confirmation_source} confirmed_model=#{audit.confirmed_model} confirmed_reasoning=#{audit.confirmed_reasoning_effort}\n"
        )

        :ok

      %{model: model} = confirmation when is_binary(model) and model != "" ->
        audit =
          Process.get(:prompt_runner_cli_confirmation_audit, %{})
          |> Map.put(:confirmed_model, model)
          |> Map.put(:confirmation_source, confirmation.source || "codex_cli.run_started")

        Process.put(:prompt_runner_cli_confirmation_audit, audit)

        IO.binwrite(
          log_io,
          "LLM_AUDIT_CONFIRMED source=#{audit.confirmation_source} confirmed_model=#{audit.confirmed_model} confirmed_reasoning=n/a\n"
        )

        :ok

      _ ->
        :ok
    end
  end

  defp maybe_print_cli_confirmation(_event, _llm, _log_io), do: :ok

  defp extract_codex_cli_confirmation(%{data: data}) when is_map(data) do
    metadata = map_get(data, :metadata)
    source = map_get(data, :confirmation_source) || "codex_cli.run_started"

    model =
      map_get(data, :confirmed_model) ||
        map_get(data, :model) ||
        map_get(metadata, :model)

    reasoning_effort =
      map_get(data, :reasoning_effort) ||
        map_get(data, :confirmed_reasoning_effort) ||
        map_get(metadata, :reasoning_effort) ||
        map_get(metadata, :reasoningEffort) ||
        case map_get(metadata, :config) do
          config when is_map(config) ->
            map_get(config, :model_reasoning_effort) || map_get(config, :reasoning_effort)

          _ ->
            nil
        end

    %{
      model: model,
      reasoning_effort: if(is_nil(reasoning_effort), do: nil, else: to_string(reasoning_effort)),
      source: source
    }
  end

  defp extract_codex_cli_confirmation(_), do: nil

  defp llm_summary(%{sdk: :codex} = llm) do
    case configured_codex_reasoning(llm) do
      nil -> "codex model=#{llm.model}"
      reasoning -> "codex model=#{llm.model} reasoning=#{reasoning} (configured)"
    end
  end

  defp llm_summary(llm), do: "#{llm.sdk} model=#{llm.model}"

  defp configured_codex_reasoning(llm) do
    case llm[:codex_thread_opts] do
      opts when is_map(opts) ->
        map_get(opts, :reasoning_effort)

      _ ->
        nil
    end
  end

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp mismatch?(configured, confirmed)
       when is_binary(configured) and configured != "" and is_binary(confirmed) and
              confirmed != "" do
    configured != confirmed
  end

  defp mismatch?(_configured, _confirmed), do: false

  defp cli_confirmation_mode(llm, config) do
    config_mode =
      case config do
        %{cli_confirmation: value} ->
          value

        map when is_map(map) ->
          Map.get(map, :cli_confirmation) || Map.get(map, "cli_confirmation")

        _ ->
          nil
      end

    mode =
      llm[:cli_confirmation] ||
        config_mode ||
        :warn

    case mode do
      value when value in [:off, :warn, :require] ->
        value

      value when is_binary(value) ->
        case String.downcase(value) do
          "off" -> :off
          "warn" -> :warn
          "require" -> :require
          _ -> :warn
        end

      _ ->
        :warn
    end
  end

  defp maybe_print_sdk_preflight(nil), do: :ok

  defp maybe_print_sdk_preflight(%{package: package, version: version, module: module}) do
    IO.puts(
      "LLM SDK preflight: package=#{package} version=#{version} module=#{module} loaded=true"
    )
  end

  defp preflight_llm_dependency(%{sdk: provider} = llm) do
    # In tests and custom integrations, a custom llm_module may fully own provider setup.
    if llm_module() != PromptRunner.LLMFacade do
      {:ok, nil}
    else
      do_preflight(provider, llm)
    end
  end

  defp preflight_llm_dependency(_), do: {:ok, nil}

  defp do_preflight(:codex, _llm) do
    cond do
      not Code.ensure_loaded?(Codex) ->
        {:error,
         {:provider_dependency_missing,
          %{
            provider: :codex,
            package: :codex_sdk,
            missing_module: "Codex",
            hint: "Add {:codex_sdk, \"== 0.8.0\"} to the entrypoint dependency set."
          }}}

      true ->
        {:ok,
         %{
           package: "codex_sdk",
           version: app_vsn(:codex_sdk),
           module: "Codex"
         }}
    end
  end

  defp do_preflight(_provider, _llm), do: {:ok, nil}

  defp app_vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  defp maybe_print_cli_mismatch(audit, log_io) do
    configured_model = Map.get(audit, :configured_model)
    configured_reasoning = Map.get(audit, :configured_reasoning_effort)
    confirmed_model = Map.get(audit, :confirmed_model)
    confirmed_reasoning = Map.get(audit, :confirmed_reasoning_effort)

    model_mismatch? =
      is_binary(configured_model) and is_binary(confirmed_model) and
        configured_model != confirmed_model

    reasoning_mismatch? =
      is_binary(configured_reasoning) and is_binary(confirmed_reasoning) and
        configured_reasoning != confirmed_reasoning

    if model_mismatch? or reasoning_mismatch? do
      warning_line =
        "WARNING: codex_cli confirmation mismatch configured_model=#{configured_model || "n/a"} configured_reasoning=#{configured_reasoning || "n/a"} confirmed_model=#{confirmed_model || "n/a"} confirmed_reasoning=#{confirmed_reasoning || "n/a"}"

      IO.puts(warning_line)
      IO.binwrite(log_io, "LLM_AUDIT_MISMATCH #{warning_line}\n")
    end
  end

  defp initialize_cli_confirmation_tracking(%{sdk: :codex} = llm, config, log_io) do
    configured_reasoning = configured_codex_reasoning(llm)
    cli_confirmation = cli_confirmation_mode(llm, config)

    audit = %{
      configured_model: llm.model,
      configured_reasoning_effort:
        if(is_nil(configured_reasoning), do: nil, else: to_string(configured_reasoning)),
      confirmed_model: nil,
      confirmed_reasoning_effort: nil,
      confirmation_source: nil,
      cli_confirmation: cli_confirmation
    }

    Process.put(:prompt_runner_cli_confirmation_printed, false)
    Process.put(:prompt_runner_cli_confirmation_audit, audit)

    IO.binwrite(
      log_io,
      "LLM_AUDIT configured_model=#{audit.configured_model || "n/a"} configured_reasoning=#{audit.configured_reasoning_effort || "n/a"} cli_confirmation=#{audit.cli_confirmation}\n"
    )
  end

  defp initialize_cli_confirmation_tracking(_llm, _config, _log_io) do
    Process.put(:prompt_runner_cli_confirmation_printed, false)
    Process.put(:prompt_runner_cli_confirmation_audit, %{})
  end

  defp maybe_finalize_cli_confirmation(result, %{sdk: :codex}, config, log_io) do
    audit = Process.get(:prompt_runner_cli_confirmation_audit, %{})
    cli_confirmation = Map.get(audit, :cli_confirmation, cli_confirmation_mode(%{}, config))

    configured_reasoning = Map.get(audit, :configured_reasoning_effort)
    configured_model = Map.get(audit, :configured_model)
    confirmed_model = Map.get(audit, :confirmed_model)
    confirmed_reasoning = Map.get(audit, :confirmed_reasoning_effort)

    status =
      cond do
        mismatch?(configured_model, confirmed_model) or
            mismatch?(configured_reasoning, confirmed_reasoning) ->
          :mismatch

        configured_reasoning != nil and confirmed_reasoning in [nil, ""] ->
          :missing

        true ->
          :matched
      end

    details = %{
      configured_model: configured_model,
      configured_reasoning: configured_reasoning,
      confirmed_model: confirmed_model,
      confirmed_reasoning: confirmed_reasoning,
      confirmation_source: Map.get(audit, :confirmation_source)
    }

    result =
      case {status, cli_confirmation} do
        {:mismatch, :require} ->
          {:error, {:cli_confirmation_mismatch, details}}

        {:missing, :require} ->
          {:error, {:cli_confirmation_missing, details}}

        {:mismatch, :warn} ->
          maybe_print_cli_mismatch(audit, log_io)
          result

        {:missing, :warn} ->
          warning_line =
            "WARNING: codex_cli confirmation missing reasoning_effort configured_model=#{configured_model || "n/a"} configured_reasoning=#{configured_reasoning || "n/a"}"

          IO.puts(warning_line)
          IO.binwrite(log_io, "LLM_AUDIT_WARNING #{warning_line}\n")
          result

        _ ->
          result
      end

    IO.binwrite(
      log_io,
      "LLM_AUDIT_RESULT status=#{status} configured_model=#{configured_model || "n/a"} configured_reasoning=#{configured_reasoning || "n/a"} confirmed_model=#{confirmed_model || "n/a"} confirmed_reasoning=#{confirmed_reasoning || "n/a"} source=#{Map.get(audit, :confirmation_source) || "n/a"} cli_confirmation=#{cli_confirmation}\n"
    )

    result
  end

  defp maybe_finalize_cli_confirmation(result, _llm, _config, _log_io), do: result

  defp write_session_header(log_io, config, llm, llm_meta, prompt_path) do
    header =
      if config.log_mode == :compact do
        tools_label =
          if is_list(llm.allowed_tools) and llm.allowed_tools != [] do
            Enum.join(llm.allowed_tools, ",")
          else
            "n/a"
          end

        "Session: sdk=#{llm_meta.sdk} model=#{llm_meta.model} tools=[#{tools_label}] cwd=#{llm_meta.cwd}\n"
      else
        "Session: #{inspect(llm_meta)}\n"
      end

    header = header <> "Prompt: #{prompt_path}\nProject: #{llm.cwd}\n\n"
    IO.binwrite(log_io, header)
  end

  defp finalize_stream_result(:ok, config, prompt, llm, skip_commit) do
    IO.puts(UI.green("LLM completed successfully"))

    commit_info =
      if skip_commit do
        {:skip, :no_commit}
      else
        commit_prompt(config, prompt, llm)
      end

    Progress.mark_completed(config, prompt.num, commit_info)
    IO.puts(UI.green("Prompt #{prompt.num} completed"))
    :ok
  end

  defp finalize_stream_result({:error, reason}, config, prompt, _llm, _skip_commit) do
    return_error(config, prompt.num, reason)
  end

  defp commit_prompt(config, prompt, _llm) do
    target_repos = resolve_target_repos(config, prompt)

    if length(target_repos) > 1 do
      Git.commit_multi_repo(config, prompt.num, target_repos)
    else
      [{repo_name, repo_path}] = target_repos
      Git.commit_single_repo(config, prompt.num, repo_name, repo_path)
    end
  end

  defp resolve_target_repos(config, prompt) do
    case prompt.target_repos do
      nil ->
        case get_default_repo(config) do
          %{name: name, path: path} -> [{name, path}]
          _ -> [{"default", config.project_dir}]
        end

      repos when is_list(repos) ->
        unless is_list(config.target_repos) do
          raise "Prompt #{prompt.num} defines target_repos but config.target_repos is not configured"
        end

        resolved_repos =
          repos
          |> RepoTargets.expand!(config.repo_groups)
          |> List.wrap()

        if resolved_repos == [] do
          raise "Prompt #{prompt.num} did not resolve any target repos from: #{Enum.join(repos, ", ")}"
        end

        Enum.map(resolved_repos, &resolve_repo_name_path(&1, config, prompt))
    end
  end

  defp resolve_repo_name_path(repo_name, config, prompt) do
    case get_repo_path(config, repo_name) do
      nil -> raise "Repo not configured for prompt #{prompt.num}: #{repo_name}"
      path -> {repo_name, path}
    end
  end

  defp get_repo_path(config, repo_name) do
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

  defp get_default_repo(config) do
    case config.target_repos do
      repos when is_list(repos) ->
        Enum.find(repos, &(&1.default == true)) || List.first(repos)

      _ ->
        nil
    end
  end

  defp format_commit_suffix(nil), do: ""
  defp format_commit_suffix("no_commit"), do: " (no_commit)"
  defp format_commit_suffix("no_changes"), do: " (no_changes)"

  defp format_commit_suffix(commit) when is_binary(commit) do
    if String.contains?(commit, "=") do
      count = commit |> String.split(",") |> length()
      " (#{count} repos)"
    else
      short = String.slice(commit, 0, 8)
      " (sha #{short})"
    end
  end

  defp format_repos_suffix(nil), do: ""
  defp format_repos_suffix([]), do: ""

  defp format_repos_suffix(repos) when is_list(repos) do
    " #{UI.dim("[#{Enum.join(repos, ",")}]")}"
  end

  defp llm_module do
    Application.get_env(:prompt_runner, :llm_module, PromptRunner.LLMFacade)
  end
end
