defmodule PromptRunner.Runner do
  @moduledoc false

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Plan
  alias PromptRunner.Progress
  alias PromptRunner.Prompts
  alias PromptRunner.Rendering
  alias PromptRunner.Rendering.Renderers.{CompactRenderer, StudioRenderer, VerboseRenderer}
  alias PromptRunner.Rendering.Sinks.{CallbackSink, FileSink, JSONLSink, TTYSink}
  alias PromptRunner.RepoTargets
  alias PromptRunner.Run
  alias PromptRunner.UI
  alias PromptRunner.Validator

  @prompt_preview_lines 10

  # Maps each provider to {otp_app, primary_module, extra_modules}.
  # Module checks match what ASM adapters guard on at compile time.
  @provider_deps %{
    claude: {:claude_agent_sdk, ClaudeAgentSDK, []},
    codex: {:codex_sdk, Codex, [Codex.Events]},
    gemini: {:gemini_cli_sdk, GeminiCliSdk, []},
    amp: {:amp_sdk, AmpSdk, []}
  }
  @resume_prompt "Continue"

  @spec run_plan(Plan.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def run_plan(%Plan{} = plan, opts \\ []) do
    plan = Plan.with_overrides(plan, opts)
    emit_observer(plan, %{type: :plan_built, plan: plan})

    opts =
      opts
      |> Keyword.put_new(:run, true)
      |> ensure_default_target()

    case do_run(plan, opts, []) do
      :ok ->
        emit_observer(plan, %{type: :run_completed, plan: plan})
        {:ok, %Run{plan: plan, status: :ok, result: :ok}}

      {:error, reason} = error ->
        emit_observer(plan, %{type: :run_completed, plan: plan, status: :error, reason: reason})
        error
    end
  end

  @spec execute_plan(Plan.t(), keyword(), list()) :: :ok | {:error, term()}
  def execute_plan(%Plan{} = plan, opts, remaining \\ []) do
    plan = Plan.with_overrides(plan, opts)
    do_run(plan, opts, remaining)
  end

  @spec list_plan(Plan.t()) :: :ok
  def list_plan(%Plan{} = plan), do: list_prompts(plan)

  @spec validate_plan(Plan.t()) :: :ok | {:error, list()}
  def validate_plan(%Plan{interface: :legacy, config: config}), do: Validator.validate_all(config)
  def validate_plan(%Plan{}), do: :ok

  defp do_run(%Plan{} = plan, opts, remaining) do
    cond do
      opts[:validate] ->
        validate_plan(plan)

      opts[:list] ->
        list_prompts(plan)

      opts[:dry_run] ->
        with {:ok, targets} <- build_targets(plan, opts, remaining) do
          Enum.each(targets, &dry_run_prompt(plan, &1, opts[:no_commit] || false))
          :ok
        end

      opts[:run] ->
        with {:ok, targets} <- build_targets(plan, opts, remaining) do
          run_targets(plan, targets, opts[:no_commit] || false)
        end

      true ->
        {:error, :no_command}
    end
  end

  defp ensure_default_target(opts) do
    if opts[:all] || opts[:phase] || opts[:continue] || opts[:run] == false do
      opts
    else
      Keyword.put(opts, :all, true)
    end
  end

  defp run_targets(plan, targets, skip_commit) do
    Enum.reduce_while(targets, :ok, fn num, _acc ->
      case run_prompt(plan, num, skip_commit) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_targets(plan, opts, remaining) do
    cond do
      remaining != [] ->
        {:ok, [hd(remaining)]}

      opts[:phase] ->
        {:ok, Prompts.phase_nums(plan, opts[:phase])}

      opts[:continue] ->
        targets =
          case Progress.last_completed(plan) do
            nil ->
              Prompts.nums(plan)

            last ->
              next =
                last
                |> String.to_integer()
                |> Kernel.+(1)
                |> Integer.to_string()
                |> String.pad_leading(2, "0")

              Prompts.nums(plan) |> Enum.filter(&(&1 >= next))
          end

        {:ok, targets}

      opts[:all] ->
        {:ok, Prompts.nums(plan)}

      true ->
        {:error, :no_target}
    end
  end

  defp list_prompts(%Plan{} = plan) do
    config = plan.config

    IO.puts("")
    IO.puts(UI.bold("Implementation Prompts"))
    IO.puts(UI.cyan("Config: #{config.config_dir}"))
    IO.puts(UI.cyan("Project: #{config.project_dir}"))
    IO.puts("")

    prompts = Prompts.list(plan)
    statuses = Progress.statuses(plan)

    {completed, total, _} =
      Enum.reduce(prompts, {0, 0, nil}, fn prompt, {c, t, last_phase} ->
        last_phase = maybe_print_phase_header(plan, prompt, last_phase)
        {line, completed_inc} = format_prompt_line(plan, statuses, prompt)
        IO.puts(line)
        {c + completed_inc, t + 1, last_phase}
      end)

    IO.puts("")
    IO.puts(UI.bold("Progress:"))
    IO.puts("#{completed}/#{total} completed")
    IO.puts("")
  end

  defp maybe_print_phase_header(plan, prompt, last_phase) do
    if prompt.phase != last_phase do
      if last_phase != nil, do: IO.puts("")
      phase_name = Map.get(plan.config.phase_names, prompt.phase, "Unknown")
      IO.puts(UI.green("Phase #{prompt.phase}: #{phase_name}"))
    end

    prompt.phase
  end

  defp format_prompt_line(plan, statuses, prompt) do
    prompt_status = Progress.status(statuses, prompt.num)

    status_label =
      case prompt_status.status do
        "completed" -> UI.green("[x]")
        "failed" -> UI.red("[!]")
        _ -> "[ ]"
      end

    completed_inc = if Progress.completed?(statuses, prompt.num), do: 1, else: 0

    prompt_path = prompt_path(plan, prompt)
    missing = if prompt_available?(prompt, prompt_path), do: "", else: " #{UI.red("(missing)")}"

    commit_suffix = format_commit_suffix(prompt_status.commit)
    repos_suffix = format_repos_suffix(prompt.target_repos)

    line =
      "  #{status_label} #{prompt.num} - #{prompt.name} (#{prompt.sp} SP)#{repos_suffix}#{commit_suffix}#{missing}"

    {line, completed_inc}
  end

  defp dry_run_prompt(plan, num, skip_commit) do
    case Prompts.get(plan, num) do
      nil ->
        IO.puts(UI.red("ERROR: Prompt #{num} not found"))

      prompt ->
        prompt_path = prompt_path(plan, prompt)
        llm = Config.llm_for_prompt(plan.config, prompt)

        IO.puts("")
        IO.puts(UI.bold("[DRY RUN] Prompt #{num}: #{prompt.name}"))
        IO.puts("")

        print_prompt_file_info(prompt, prompt_path)
        print_execution_info(plan, prompt, llm)
        print_git_commit_info(plan, prompt, skip_commit)

        IO.puts("")
    end
  end

  defp print_prompt_file_info(prompt, prompt_path) do
    IO.puts(UI.yellow("1. Prompt file:"))

    cond do
      is_binary(prompt.body) ->
        lines = prompt.body |> String.split("\n") |> length()
        IO.puts("   #{prompt_path}")
        IO.puts("   #{lines} lines, #{byte_size(prompt.body)} bytes")

      File.exists?(prompt_path) ->
        stat = File.stat!(prompt_path)
        lines = prompt_path |> File.read!() |> String.split("\n") |> length()
        IO.puts("   #{prompt_path}")
        IO.puts("   #{lines} lines, #{stat.size} bytes")

      true ->
        IO.puts("   #{UI.red("NOT FOUND:")} #{prompt_path}")
    end

    IO.puts("")
  end

  defp print_execution_info(plan, prompt, llm) do
    IO.puts(UI.yellow("2. Execution:"))
    IO.puts("   LLM provider: #{llm.sdk}")
    IO.puts("   - model: #{llm.model}")
    maybe_print_codex_reasoning(llm)
    IO.puts("   - cwd: #{llm.cwd}")
    maybe_print_allowed_tools(llm)
    maybe_print_permission_mode(llm)
    maybe_print_adapter_opts(llm)
    maybe_print_codex_thread_opts(llm)
    print_target_repos(plan, prompt)
    IO.puts("")
  end

  defp maybe_print_codex_reasoning(%{sdk: :codex} = llm) do
    case configured_codex_reasoning(llm) do
      nil -> :ok
      reasoning -> IO.puts("   - reasoning_effort: #{reasoning}")
    end
  end

  defp maybe_print_codex_reasoning(_llm), do: :ok

  defp maybe_print_allowed_tools(llm) do
    if is_list(llm.allowed_tools) do
      IO.puts("   - allowed_tools: #{Enum.join(llm.allowed_tools, ", ")}")
    end
  end

  defp maybe_print_permission_mode(llm) do
    if llm.permission_mode != nil do
      IO.puts("   - permission_mode: #{llm.permission_mode}")
    end
  end

  defp maybe_print_adapter_opts(llm) do
    if is_map(llm[:adapter_opts]) and map_size(llm.adapter_opts) > 0 do
      IO.puts("   - adapter_opts: #{inspect(llm.adapter_opts)}")
    end
  end

  defp maybe_print_codex_thread_opts(%{sdk: :codex} = llm) do
    if is_map(llm[:codex_thread_opts]) and map_size(llm.codex_thread_opts) > 0 do
      IO.puts("   - codex_thread_opts: #{inspect(llm.codex_thread_opts)}")
    end
  end

  defp maybe_print_codex_thread_opts(_llm), do: :ok

  defp print_target_repos(plan, prompt) do
    config = plan.config

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
          repo_path = get_repo_path(plan, repo_name)
          IO.puts("     - #{repo_name}: #{repo_path || "(not configured)"}")
        end)
    end
  end

  defp print_git_commit_info(plan, prompt, skip_commit) do
    IO.puts(UI.yellow("3. Git commit:"))

    if skip_commit do
      IO.puts("   SKIPPED (--no-commit)")
    else
      print_commit_messages(plan, prompt)
    end

    IO.puts("")
  end

  defp print_commit_messages(plan, prompt) do
    case prompt.target_repos do
      nil ->
        print_single_commit_message(plan, prompt)

      repos when is_list(repos) ->
        {resolved_repos, errors} = RepoTargets.expand(repos, plan.config.repo_groups)

        Enum.each(errors, fn error ->
          IO.puts("   #{UI.red("ERR")} #{RepoTargets.format_error(error)}")
        end)

        Enum.each(resolved_repos, &print_repo_commit_message(plan, prompt, &1))
    end
  end

  defp print_single_commit_message(plan, prompt) do
    case CommitMessages.get_message(plan, prompt.num) do
      nil ->
        IO.puts("   #{UI.red("COMMIT MESSAGE NOT FOUND")} for #{prompt.num}")

      msg ->
        show_commit_message_preview(msg, nil)
    end
  end

  defp print_repo_commit_message(plan, prompt, repo_name) do
    IO.puts("   #{UI.bold(repo_name <> ":")}")

    case CommitMessages.get_message(plan, prompt.num, repo_name) do
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

  defp run_prompt(plan, num, skip_commit) do
    case Prompts.get(plan, num) do
      nil ->
        {:error, {:prompt_not_found, num}}

      prompt ->
        prompt_path = prompt_path(plan, prompt)
        llm = Config.llm_for_prompt(plan.config, prompt)

        emit_observer(plan, %{type: :prompt_started, prompt: prompt})

        with :ok <- ensure_prompt_file(prompt, prompt_path),
             {:ok, sdk_info} <- preflight_llm_dependency(llm) do
          execute_prompt_stream(plan, num, prompt, prompt_path, llm, sdk_info, skip_commit)
        else
          {:error, reason} ->
            return_error(plan, num, reason)
        end
    end
  end

  defp ensure_prompt_file(%{body: body}, _prompt_path) when is_binary(body), do: :ok

  defp ensure_prompt_file(_prompt, prompt_path) do
    if File.exists?(prompt_path), do: :ok, else: {:error, {:prompt_file_not_found, prompt_path}}
  end

  defp execute_prompt_stream(plan, num, prompt, prompt_path, llm, sdk_info, skip_commit) do
    config = plan.config
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")
    {log_file, log_io, close_log, events_file} = open_log_device(plan, num, timestamp)

    print_prompt_header(plan, prompt, llm, log_file)
    maybe_print_sdk_preflight(sdk_info)

    if config.log_mode != :studio and is_binary(events_file) do
      IO.puts("Events: #{events_file}")
      IO.puts("")
    end

    prompt_content = prompt_content(prompt, prompt_path)

    IO.puts(UI.yellow("Prompt preview (first #{@prompt_preview_lines} lines):"))

    prompt_content
    |> String.split("\n")
    |> Enum.take(@prompt_preview_lines)
    |> Enum.each(&IO.puts("  #{&1}"))

    IO.puts("  ...")
    IO.puts("")

    if config.log_mode != :studio do
      IO.puts(UI.yellow("Starting #{llm.sdk} session..."))
      IO.puts("")
    end

    llm_module().start_stream(llm, prompt_content)
    |> handle_stream_result(
      plan,
      prompt,
      prompt_path,
      llm,
      {log_io, close_log, events_file},
      skip_commit
    )
  end

  defp handle_stream_result(
         {:ok, stream, close_llm, llm_meta},
         plan,
         prompt,
         prompt_path,
         llm,
         {log_io, close_log, events_file},
         skip_commit
       ) do
    config = plan.config
    Process.put(:prompt_runner_additional_closers, [])

    try do
      write_session_header(log_io, config, llm, llm_meta, prompt_path)
      initialize_cli_confirmation_tracking(llm, config, log_io)

      renderer = renderer_for_config(config)
      sinks = build_sinks(plan, log_io, events_file, llm)

      recovery = %{
        renderer: renderer,
        sinks: sinks,
        llm: llm,
        llm_meta: llm_meta,
        plan: plan,
        prompt: prompt,
        log_io: log_io
      }

      {result, extra_closers} = run_stream_with_recovery(stream, recovery)

      Process.put(:prompt_runner_additional_closers, extra_closers)
      Process.delete(:prompt_runner_cli_confirmation_printed)
      Process.delete(:prompt_runner_cli_confirmation_audit)

      IO.puts("")
      finalize_stream_result(result, plan, prompt, llm, skip_commit)
    after
      Enum.each(
        Process.get(:prompt_runner_additional_closers, []) ++ [close_llm],
        &safe_close_fun/1
      )

      Process.delete(:prompt_runner_additional_closers)
      close_log.()
    end
  end

  defp handle_stream_result(
         {:error, reason},
         plan,
         prompt,
         _prompt_path,
         _llm,
         {_log_io, close_log, _events_file},
         _skip_commit
       ) do
    close_log.()
    return_error(plan, prompt.num, {:start_failed, reason})
  end

  defp return_error(plan, num, reason) do
    {summary, stderr_detail, stderr_truncated?} = format_error_reason(reason, plan.config)

    IO.puts(UI.red("ERROR: #{summary}"))

    if is_binary(stderr_detail) and stderr_detail != "" do
      IO.puts(UI.red("stderr:"))

      stderr_detail
      |> String.split("\n", trim: false)
      |> Enum.each(&IO.puts("  #{&1}"))

      if stderr_truncated? do
        IO.puts("  [truncated]")
      end
    end

    Progress.mark_failed(plan, num)
    emit_observer(plan, %{type: :prompt_failed, prompt_num: num, reason: reason})
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
      :studio -> {StudioRenderer, studio_opts(config)}
      :verbose -> {VerboseRenderer, []}
      _ -> {CompactRenderer, []}
    end
  end

  defp studio_opts(config) do
    opts = [tool_output: config.tool_output]
    if config.log_mode == :studio, do: opts, else: []
  end

  defp print_prompt_header(plan, prompt, llm, log_file) do
    config = plan.config

    IO.puts("")

    if config.log_mode == :studio do
      bar = UI.dim(String.duplicate("━", 60))
      IO.puts(bar)
      IO.puts(UI.bold("  Prompt #{prompt.num}: #{prompt.name}"))
      IO.puts(bar)
      IO.puts("")
      IO.puts("  #{UI.dim("Prompt")}   #{prompt_path(plan, prompt)}")
      IO.puts("  #{UI.dim("Project")}  #{llm.cwd}")
      IO.puts("  #{UI.dim("LLM")}      #{llm.sdk} / #{llm.model}")
      IO.puts("  #{UI.dim("Log")}      #{log_file}")
      IO.puts("")
    else
      IO.puts(UI.blue(String.duplicate("=", 60)))
      IO.puts(UI.bold("Prompt #{prompt.num}: #{prompt.name}"))
      IO.puts(UI.blue(String.duplicate("=", 60)))
      IO.puts("")
      IO.puts("Prompt: #{prompt_path(plan, prompt)}")
      IO.puts("Project: #{llm.cwd}")
      IO.puts("LLM: #{llm_summary(llm)}")
      IO.puts("")
      IO.puts("Log: #{log_file}")
    end
  end

  defp build_sinks(plan, log_io, events_file, llm) do
    config = plan.config

    sinks = [
      {TTYSink, []},
      {FileSink, [io: log_io]},
      {CallbackSink,
       [
         callback: fn event, iodata ->
           stream_tracking_callback(plan, event, iodata, llm, log_io)
         end
       ]}
    ]

    if config.events_mode != :off and is_binary(events_file) do
      sinks ++ [{JSONLSink, [path: events_file, mode: config.events_mode]}]
    else
      sinks
    end
  end

  defp stream_tracking_callback(plan, event, _iodata, llm, log_io) do
    emit_observer(plan, Map.put(event, :raw?, true))
    maybe_print_cli_confirmation(event, llm, log_io)
    maybe_log_recovery_metadata(event, log_io)
    error_tracking_callback(event)
  end

  defp error_tracking_callback(event) do
    case event.type do
      type when type in [:error_occurred, :run_failed] ->
        data = map_get(event, :data) || %{}
        provider_error = map_get(data, :provider_error)
        details = map_get(data, :details)

        summary =
          map_get(provider_error, :message) || map_get(data, :error_message) || "unknown error"

        result =
          if is_map(provider_error) do
            {:error, %{message: summary, provider_error: provider_error, details: details}}
          else
            {:error, summary}
          end

        if Process.get(:prompt_runner_stream_result) == nil do
          Process.put(:prompt_runner_stream_result, result)
        end

      _ ->
        :ok
    end
  end

  defp run_stream_with_recovery(stream, recovery, attempt \\ 0) do
    result =
      render_stream_attempt(
        stream,
        recovery.renderer,
        recovery.sinks,
        recovery.llm,
        recovery.plan,
        recovery.log_io
      )

    case maybe_resume_failed_stream(result, recovery, attempt) do
      {:resume, resumed_stream, resumed_close, resumed_meta} ->
        {resumed_result, extra_closers} =
          run_stream_with_recovery(
            resumed_stream,
            %{recovery | llm_meta: resumed_meta},
            attempt + 1
          )

        {resumed_result, [resumed_close | extra_closers]}

      {:resume_failed, merged_result} ->
        {merged_result, []}

      :no_resume ->
        {result, []}
    end
  end

  defp render_stream_attempt(stream, renderer, sinks, llm, plan, log_io) do
    Process.delete(:prompt_runner_stream_result)

    render_result = safe_render_stream(stream, renderer, sinks)
    callback_result = Process.get(:prompt_runner_stream_result, :ok)
    Process.delete(:prompt_runner_stream_result)

    render_result
    |> resolve_stream_result(callback_result)
    |> maybe_finalize_cli_confirmation(llm, plan, log_io)
  end

  defp maybe_resume_failed_stream(result, recovery, attempt) do
    cond do
      result == :ok ->
        :no_resume

      attempt > 0 ->
        :no_resume

      not recoverable_stream_error?(result) ->
        :no_resume

      true ->
        emit_observer(recovery.plan, %{
          type: :session_resume_attempted,
          prompt: recovery.prompt,
          reason: result,
          provider: recovery.llm.sdk,
          message: @resume_prompt
        })

        IO.puts("Resuming provider session with #{@resume_prompt}...")

        IO.binwrite(
          recovery.log_io,
          "SESSION_RECOVERY action=resume_attempt provider=#{recovery.llm.sdk} prompt=#{inspect(@resume_prompt)} reason=#{inspect(result)}\n"
        )

        case llm_module().resume_stream(recovery.llm, recovery.llm_meta, @resume_prompt) do
          {:ok, resumed_stream, resumed_close, resumed_meta} ->
            emit_observer(recovery.plan, %{
              type: :session_resume_started,
              prompt: recovery.prompt,
              provider: recovery.llm.sdk,
              message: @resume_prompt
            })

            IO.binwrite(
              recovery.log_io,
              "SESSION_RECOVERY action=resume_started provider=#{recovery.llm.sdk} prompt=#{inspect(@resume_prompt)}\n"
            )

            {:resume, resumed_stream, resumed_close, resumed_meta}

          {:error, resume_reason} ->
            merged_result = merge_root_and_resume_error(result, {:error, resume_reason})

            emit_observer(recovery.plan, %{
              type: :session_resume_failed,
              prompt: recovery.prompt,
              provider: recovery.llm.sdk,
              root_reason: result,
              resume_reason: resume_reason
            })

            IO.binwrite(
              recovery.log_io,
              "SESSION_RECOVERY action=resume_failed provider=#{recovery.llm.sdk} reason=#{inspect(resume_reason)}\n"
            )

            {:resume_failed, merged_result}
        end
    end
  end

  defp maybe_log_recovery_metadata(event, log_io) do
    case event do
      %{type: :run_started, data: data, provider: provider} when is_map(data) ->
        provider_session_id = map_get(data, :provider_session_id)

        if is_binary(provider_session_id) and
             Process.get(:prompt_runner_session_recovery_logged) != provider_session_id do
          Process.put(:prompt_runner_session_recovery_logged, provider_session_id)

          IO.binwrite(
            log_io,
            "SESSION_RECOVERY action=checkpoint provider=#{provider} provider_session_id=#{provider_session_id}\n"
          )
        end

      _ ->
        :ok
    end
  end

  defp recoverable_stream_error?({:error, reason}) do
    provider_error = extract_provider_error(reason)
    kind = map_get(provider_error, :kind)

    message =
      String.downcase(map_get(provider_error, :message) || map_get(reason, :message) || "")

    kind in [:protocol_error, :transport_error, :transport_exit] or
      String.contains?(message, "websocket protocol error") or
      String.contains?(message, "connection reset without closing handshake")
  end

  defp recoverable_stream_error?(_result), do: false

  defp merge_root_and_resume_error({:error, root_reason}, {:error, resume_reason}) do
    root_message =
      map_get(root_reason, :message) ||
        map_get(extract_provider_error(root_reason), :message) ||
        if(is_binary(root_reason), do: root_reason, else: inspect(root_reason))

    {:error,
     %{
       message: root_message,
       provider_error: extract_provider_error(root_reason),
       details: map_get(root_reason, :details),
       root_cause: root_reason,
       recovery_error: resume_reason
     }}
  end

  defp merge_root_and_resume_error(root_result, _resume_result), do: root_result

  defp format_error_reason(reason, config) do
    provider_error = extract_provider_error(reason)

    summary =
      map_get(reason, :message) ||
        map_get(provider_error, :message) ||
        if(is_binary(reason), do: reason, else: inspect(reason))

    stderr_detail =
      if show_provider_stderr?(config) do
        map_get(provider_error, :stderr)
      else
        nil
      end

    {summary, stderr_detail, truthy?(map_get(provider_error, :truncated?))}
  end

  defp extract_provider_error(reason) do
    case map_get(reason, :provider_error) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp show_provider_stderr?(%{log_meta: :full}), do: true
  defp show_provider_stderr?(_config), do: false

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_), do: false

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

    %{
      model: confirmation_model(data, metadata),
      reasoning_effort: confirmation_reasoning_effort(data, metadata) |> stringify_or_nil(),
      source: confirmation_source(data)
    }
  end

  defp extract_codex_cli_confirmation(_), do: nil

  defp confirmation_source(data) do
    map_get(data, :confirmation_source) || "codex_cli.run_started"
  end

  defp confirmation_model(data, metadata) do
    map_get(data, :confirmed_model) ||
      map_get(data, :model) ||
      map_get(metadata, :model)
  end

  defp confirmation_reasoning_effort(data, metadata) do
    map_get(data, :reasoning_effort) ||
      map_get(data, :confirmed_reasoning_effort) ||
      map_get(metadata, :reasoning_effort) ||
      map_get(metadata, :reasoningEffort) ||
      metadata_config_reasoning(metadata)
  end

  defp metadata_config_reasoning(metadata) do
    case map_get(metadata, :config) do
      config when is_map(config) ->
        map_get(config, :model_reasoning_effort) || map_get(config, :reasoning_effort)

      _ ->
        nil
    end
  end

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

  defp map_get(_map, _key), do: nil

  defp mismatch?(configured, confirmed)
       when is_binary(configured) and configured != "" and is_binary(confirmed) and
              confirmed != "" do
    configured != confirmed
  end

  defp mismatch?(_configured, _confirmed), do: false

  defp cli_confirmation_mode(llm, config) do
    llm[:cli_confirmation]
    |> Kernel.||(config_cli_confirmation(config))
    |> Kernel.||(:warn)
    |> normalize_cli_confirmation_mode()
  end

  defp config_cli_confirmation(%{cli_confirmation: value}), do: value

  defp normalize_cli_confirmation_mode(value) when value in [:off, :warn, :require], do: value

  defp normalize_cli_confirmation_mode(value) when is_binary(value) do
    value
    |> String.downcase()
    |> normalize_cli_confirmation_mode_from_string()
  end

  defp normalize_cli_confirmation_mode(_), do: :warn

  defp normalize_cli_confirmation_mode_from_string("off"), do: :off
  defp normalize_cli_confirmation_mode_from_string("warn"), do: :warn
  defp normalize_cli_confirmation_mode_from_string("require"), do: :require
  defp normalize_cli_confirmation_mode_from_string(_), do: :warn

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

  defp do_preflight(provider, _llm) do
    case Map.fetch(@provider_deps, provider) do
      {:ok, {otp_app, primary_mod, extra_mods}} ->
        all_mods = [primary_mod | extra_mods]

        if Enum.all?(all_mods, &Code.ensure_loaded?/1) do
          {:ok,
           %{
             package: Atom.to_string(otp_app),
             version: app_vsn(otp_app),
             module: inspect(primary_mod)
           }}
        else
          missing =
            all_mods
            |> Enum.reject(&Code.ensure_loaded?/1)
            |> Enum.map_join(", ", &inspect/1)

          {:error,
           {:provider_dependency_missing,
            %{
              provider: provider,
              package: otp_app,
              missing_module: missing,
              hint: dep_hint(otp_app)
            }}}
        end

      :error ->
        {:ok, nil}
    end
  end

  defp dep_hint(otp_app) do
    version_spec =
      case app_vsn(otp_app) do
        "unknown" -> dep_fallback_spec(otp_app)
        vsn -> "~> #{vsn}"
      end

    "Add {#{inspect(otp_app)}, #{inspect(version_spec)}} to the deps in your mix.exs."
  end

  defp dep_fallback_spec(:codex_sdk), do: "~> 0.9.0"
  defp dep_fallback_spec(:claude_agent_sdk), do: "~> 0.13.0"
  defp dep_fallback_spec(:gemini_cli_sdk), do: "~> 0.2.0"
  defp dep_fallback_spec(:amp_sdk), do: "~> 0.3"
  defp dep_fallback_spec(_), do: ">= 0.0.0"

  @doc false
  @spec check_provider_dependency(atom()) :: {:ok, map() | nil} | {:error, term()}
  def check_provider_dependency(provider), do: do_preflight(provider, %{})

  defp app_vsn(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      vsn when is_list(vsn) -> List.to_string(vsn)
      vsn -> to_string(vsn)
    end
  end

  defp maybe_print_cli_mismatch(audit, log_io) do
    if cli_confirmation_mismatch?(audit) do
      warning_line = cli_mismatch_warning_line(audit)
      IO.puts(warning_line)
      IO.binwrite(log_io, "LLM_AUDIT_MISMATCH #{warning_line}\n")
    end
  end

  defp cli_confirmation_mismatch?(audit) do
    mismatch?(Map.get(audit, :configured_model), Map.get(audit, :confirmed_model)) or
      mismatch?(
        Map.get(audit, :configured_reasoning_effort),
        Map.get(audit, :confirmed_reasoning_effort)
      )
  end

  defp cli_mismatch_warning_line(audit) do
    "WARNING: codex_cli confirmation mismatch configured_model=#{Map.get(audit, :configured_model) || "n/a"} configured_reasoning=#{Map.get(audit, :configured_reasoning_effort) || "n/a"} confirmed_model=#{Map.get(audit, :confirmed_model) || "n/a"} confirmed_reasoning=#{Map.get(audit, :confirmed_reasoning_effort) || "n/a"}"
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
    Process.delete(:prompt_runner_session_recovery_logged)

    IO.binwrite(
      log_io,
      "LLM_AUDIT configured_model=#{audit.configured_model || "n/a"} configured_reasoning=#{audit.configured_reasoning_effort || "n/a"} cli_confirmation=#{audit.cli_confirmation}\n"
    )
  end

  defp initialize_cli_confirmation_tracking(_llm, _config, _log_io) do
    Process.put(:prompt_runner_cli_confirmation_printed, false)
    Process.put(:prompt_runner_cli_confirmation_audit, %{})
    Process.delete(:prompt_runner_session_recovery_logged)
  end

  defp maybe_finalize_cli_confirmation(result, %{sdk: :codex}, plan, log_io) do
    config = plan.config
    audit = Process.get(:prompt_runner_cli_confirmation_audit, %{})
    cli_confirmation = Map.get(audit, :cli_confirmation, cli_confirmation_mode(%{}, config))
    details = cli_confirmation_details(audit)
    status = cli_confirmation_status(details)

    result =
      apply_cli_confirmation_policy(result, status, cli_confirmation, details, audit, log_io)

    write_cli_audit_result(log_io, status, details, cli_confirmation)
    result
  end

  defp maybe_finalize_cli_confirmation(result, _llm, _plan, _log_io), do: result

  defp cli_confirmation_details(audit) do
    %{
      configured_model: Map.get(audit, :configured_model),
      configured_reasoning: Map.get(audit, :configured_reasoning_effort),
      confirmed_model: Map.get(audit, :confirmed_model),
      confirmed_reasoning: Map.get(audit, :confirmed_reasoning_effort),
      confirmation_source: Map.get(audit, :confirmation_source)
    }
  end

  defp cli_confirmation_status(%{
         configured_model: configured_model,
         configured_reasoning: configured_reasoning,
         confirmed_model: confirmed_model,
         confirmed_reasoning: confirmed_reasoning
       }) do
    cond do
      mismatch?(configured_model, confirmed_model) or
          mismatch?(configured_reasoning, confirmed_reasoning) ->
        :mismatch

      configured_reasoning != nil and confirmed_reasoning in [nil, ""] ->
        :missing

      true ->
        :matched
    end
  end

  defp apply_cli_confirmation_policy(result, status, cli_confirmation, details, audit, log_io) do
    case {status, cli_confirmation} do
      {:mismatch, :require} ->
        {:error, {:cli_confirmation_mismatch, details}}

      {:missing, :require} ->
        {:error, {:cli_confirmation_missing, details}}

      {:mismatch, :warn} ->
        maybe_print_cli_mismatch(audit, log_io)
        result

      {:missing, :warn} ->
        maybe_print_cli_missing_warning(details, log_io)
        result

      _ ->
        result
    end
  end

  defp maybe_print_cli_missing_warning(details, log_io) do
    warning_line =
      "WARNING: codex_cli confirmation missing reasoning_effort configured_model=#{details.configured_model || "n/a"} configured_reasoning=#{details.configured_reasoning || "n/a"}"

    IO.puts(warning_line)
    IO.binwrite(log_io, "LLM_AUDIT_WARNING #{warning_line}\n")
  end

  defp write_cli_audit_result(log_io, status, details, cli_confirmation) do
    IO.binwrite(
      log_io,
      "LLM_AUDIT_RESULT status=#{status} configured_model=#{details.configured_model || "n/a"} configured_reasoning=#{details.configured_reasoning || "n/a"} confirmed_model=#{details.confirmed_model || "n/a"} confirmed_reasoning=#{details.confirmed_reasoning || "n/a"} source=#{details.confirmation_source || "n/a"} cli_confirmation=#{cli_confirmation}\n"
    )
  end

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value), do: to_string(value)

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

  defp finalize_stream_result(:ok, plan, prompt, llm, skip_commit) do
    commit_info =
      if skip_commit do
        {:skip, :no_commit}
      else
        commit_prompt(plan, prompt, llm)
      end

    Progress.mark_completed(plan, prompt.num, commit_info)
    emit_observer(plan, %{type: :prompt_completed, prompt: prompt, commit_info: commit_info})

    if plan.config.log_mode == :studio do
      IO.puts(UI.green("  ✓ Prompt #{prompt.num} completed"))
    else
      IO.puts(UI.green("LLM completed successfully"))
      IO.puts(UI.green("Prompt #{prompt.num} completed"))
    end

    :ok
  end

  defp finalize_stream_result({:error, reason}, plan, prompt, _llm, _skip_commit) do
    emit_observer(plan, %{type: :prompt_failed, prompt: prompt, reason: reason})
    return_error(plan, prompt.num, reason)
  end

  defp commit_prompt(plan, prompt, _llm) do
    {module, opts} = plan.committer
    module.commit(plan, prompt, %{}, opts)
  end

  defp get_repo_path(%Plan{config: config}, repo_name), do: get_repo_path(config, repo_name)

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

  defp prompt_path(%Plan{config: config}, prompt), do: prompt_path(config, prompt)

  defp prompt_path(_config, %{origin: %{path: path}}) when is_binary(path), do: path

  defp prompt_path(config, %{file: file}) when is_binary(file),
    do: Path.join(config.config_dir, file)

  defp prompt_path(_config, _prompt), do: "(inline prompt)"

  defp prompt_available?(%{body: body}, _path) when is_binary(body), do: true
  defp prompt_available?(_prompt, path), do: File.exists?(path)

  defp prompt_content(%{body: body}, _path) when is_binary(body), do: body
  defp prompt_content(_prompt, path), do: File.read!(path)

  defp open_log_device(%PromptRunner.Plan{runtime_store: {module, state}}, num, timestamp) do
    paths = module.log_paths(state, num, timestamp)
    open_log_device(paths.log_file, paths.events_file)
  end

  defp open_log_device(log_file, events_file) when is_binary(log_file) do
    File.mkdir_p!(Path.dirname(log_file))
    {:ok, log_io} = File.open(log_file, [:write, :utf8])
    {log_file, log_io, fn -> File.close(log_io) end, events_file}
  end

  defp open_log_device(_log_file, _events_file) do
    {:ok, log_io} = StringIO.open("")
    {"(memory)", log_io, fn -> StringIO.close(log_io) end, nil}
  end

  defp emit_observer(%PromptRunner.Plan{callbacks: callbacks}, event) when is_map(callbacks) do
    maybe_invoke_callback(callbacks[:on_event], event)

    case event.type do
      :prompt_started -> maybe_invoke_callback(callbacks[:on_prompt_started], event)
      :prompt_completed -> maybe_invoke_callback(callbacks[:on_prompt_completed], event)
      :prompt_failed -> maybe_invoke_callback(callbacks[:on_prompt_failed], event)
      :run_completed -> maybe_invoke_callback(callbacks[:on_run_completed], event)
      _ -> :ok
    end
  end

  defp maybe_invoke_callback(fun, event) when is_function(fun, 1), do: fun.(event)
  defp maybe_invoke_callback(_fun, _event), do: :ok

  defp safe_close_fun(fun) when is_function(fun, 0) do
    fun.()
    :ok
  rescue
    _error -> :ok
  catch
    :exit, _reason -> :ok
  end

  defp safe_close_fun(_fun), do: :ok

  defp llm_module do
    Application.get_env(:prompt_runner, :llm_module, PromptRunner.LLMFacade)
  end
end
