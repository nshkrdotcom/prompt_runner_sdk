defmodule PromptRunner.Runner do
  @moduledoc false

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.FailureEnvelope
  alias PromptRunner.Plan
  alias PromptRunner.Progress
  alias PromptRunner.Prompts
  alias PromptRunner.RecoveryPolicy
  alias PromptRunner.Rendering
  alias PromptRunner.Rendering.Renderers.{CompactRenderer, StudioRenderer, VerboseRenderer}
  alias PromptRunner.Rendering.Sinks.{CallbackSink, FileSink, JSONLSink, TTYSink}
  alias PromptRunner.RepoTargets
  alias PromptRunner.Run
  alias PromptRunner.Runtime
  alias PromptRunner.UI
  alias PromptRunner.Validator
  alias PromptRunner.Verifier

  @prompt_preview_lines 10
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

  @spec repair_plan(Plan.t(), String.t(), keyword()) :: {:ok, Run.t()} | {:error, term()}
  def repair_plan(%Plan{} = plan, prompt_id, opts \\ []) do
    plan = Plan.with_overrides(plan, opts)
    prompt_id = normalize_prompt_id(prompt_id)

    with {:ok, prompt} <- fetch_prompt(plan, prompt_id),
         {:ok, prompt_state} <- Runtime.prompt_state(plan, prompt.num),
         :ok <-
           run_prompt_attempts(
             plan,
             build_repair_prompt(prompt, prompt_state),
             opts[:no_commit] || false,
             :repair,
             1
           ) do
      {:ok, %Run{plan: plan, status: :ok, result: :ok}}
    end
  end

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
        run_prompt_attempts(plan, prompt, skip_commit, :run, 1)
    end
  end

  defp run_prompt_attempts(plan, prompt, skip_commit, mode, attempt) do
    ctx = prompt_attempt_context(plan, prompt, skip_commit, mode, attempt)

    emit_observer(plan, %{type: :prompt_started, prompt: prompt, mode: mode, attempt: attempt})
    Runtime.record_attempt_started(plan, prompt, attempt, to_string(mode))

    with :ok <- ensure_prompt_file(prompt, ctx.prompt_path),
         {:ok, provider_info} <- preflight_llm_provider(ctx.llm) do
      ctx
      |> Map.put(:provider_info, provider_info)
      |> execute_prompt_stream()
      |> handle_attempt_outcome(ctx)
    else
      {:error, reason} ->
        record_attempt_failure(ctx, reason)

        return_error(plan, prompt.num, reason)
    end
  end

  defp ensure_prompt_file(%{body: body}, _prompt_path) when is_binary(body), do: :ok

  defp ensure_prompt_file(_prompt, prompt_path) do
    if File.exists?(prompt_path), do: :ok, else: {:error, {:prompt_file_not_found, prompt_path}}
  end

  defp execute_prompt_stream(ctx) do
    config = ctx.plan.config
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%d-%H%M%S")

    {log_file, log_io, close_log, events_file} =
      open_log_device(ctx.plan, ctx.prompt.num, timestamp)

    log_ctx = %{
      log_file: log_file,
      log_io: log_io,
      close_log: close_log,
      events_file: events_file
    }

    print_prompt_header(ctx.plan, ctx.prompt, ctx.llm, log_file)
    maybe_print_provider_preflight(ctx.provider_info)

    if config.log_mode != :studio and is_binary(events_file) do
      IO.puts("Events: #{events_file}")
      IO.puts("")
    end

    prompt_content = prompt_content(ctx.prompt, ctx.prompt_path)

    IO.puts(UI.yellow("Prompt preview (first #{@prompt_preview_lines} lines):"))

    prompt_content
    |> String.split("\n")
    |> Enum.take(@prompt_preview_lines)
    |> Enum.each(&IO.puts("  #{&1}"))

    IO.puts("  ...")
    IO.puts("")

    if config.log_mode != :studio do
      IO.puts(UI.yellow("Starting #{ctx.llm.sdk} session..."))
      IO.puts("")
    end

    llm_module().start_stream(ctx.llm, prompt_content)
    |> handle_stream_result(ctx, log_ctx)
  end

  defp handle_stream_result({:ok, stream, close_llm, llm_meta}, ctx, log_ctx) do
    config = ctx.plan.config
    Process.put(:prompt_runner_additional_closers, [])

    try do
      write_session_header(log_ctx.log_io, config, ctx.llm, llm_meta, ctx.prompt_path)
      initialize_cli_confirmation_tracking(ctx.llm, config, log_ctx.log_io)

      {result, extra_closers} =
        run_stream_with_recovery(stream, recovery_context(ctx, llm_meta, log_ctx))

      Process.put(:prompt_runner_additional_closers, extra_closers)
      Process.delete(:prompt_runner_cli_confirmation_printed)
      Process.delete(:prompt_runner_cli_confirmation_audit)

      IO.puts("")
      finalize_stream_result(result, ctx)
    after
      Enum.each(
        Process.get(:prompt_runner_additional_closers, []) ++ [close_llm],
        &safe_close_fun/1
      )

      Process.delete(:prompt_runner_additional_closers)
      log_ctx.close_log.()
    end
  end

  defp handle_stream_result({:error, reason}, ctx, log_ctx) do
    log_ctx.close_log.()

    Runtime.record_attempt_result(ctx.plan, ctx.prompt.num, ctx.attempt, %{
      "status" => "failed",
      "failure_class" => failure_class(reason),
      "reason" => summarize_reason({:start_failed, reason})
    })

    return_error(ctx.plan, ctx.prompt.num, {:start_failed, reason})
  end

  defp return_error(plan, num, reason, mark_failed \\ true) do
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

    if mark_failed do
      Progress.mark_failed(plan, num)
    end

    emit_observer(plan, %{type: :prompt_failed, prompt_num: num, reason: reason})
    {:error, reason}
  end

  defp attempt_status(:ok, report),
    do: if(report.pass?, do: "completed", else: "verification_failed")

  defp attempt_status({:error, _reason} = stream_result, report) do
    cond do
      report.pass? and verification_override_allowed?(stream_result, report) ->
        "completed"

      report.pass? ->
        "failed"

      true ->
        "failed"
    end
  end

  defp stream_failure_class(:ok), do: nil
  defp stream_failure_class({:error, reason}), do: failure_class(reason)

  defp failure_for_stream_result(:ok), do: FailureEnvelope.success()
  defp failure_for_stream_result({:error, reason}), do: FailureEnvelope.from_reason(reason)

  defp stream_reason(:ok), do: nil
  defp stream_reason({:error, reason}), do: summarize_reason(reason)

  defp summarize_reason(reason) do
    provider_error = extract_provider_error(reason)

    map_get(reason, :message) ||
      map_get(provider_error, :message) ||
      if(is_binary(reason), do: reason, else: inspect(reason))
  end

  defp print_completion_success(plan, prompt) do
    if plan.config.log_mode == :studio do
      IO.puts(UI.green("  ✓ Prompt #{prompt.num} completed"))
    else
      IO.puts(UI.green("LLM completed successfully"))
      IO.puts(UI.green("Prompt #{prompt.num} completed"))
    end
  end

  defp verification_override_allowed?({:error, {:cli_confirmation_missing, _details}}, _report),
    do: false

  defp verification_override_allowed?({:error, {:cli_confirmation_mismatch, _details}}, _report),
    do: false

  defp verification_override_allowed?({:error, reason}, report) do
    failure = FailureEnvelope.from_reason(reason)

    verifier_items_present?(report) and
      failure.class not in [
        :cli_confirmation_missing,
        :cli_confirmation_mismatch,
        :approval_denied
      ]
  end

  defp verifier_items_present?(report) when is_map(report) do
    items = Map.get(report, :items, Map.get(report, "items", []))
    is_list(items) and items != []
  end

  defp build_repair_prompt(prompt, prompt_state) do
    verifier = prompt_state["last_verifier"] || prompt_state["verifier"] || %{}

    failures =
      verifier
      |> Map.get("failures", verifier[:failures] || [])
      |> Enum.map_join("\n- ", fn failure ->
        failure
        |> Enum.into(%{})
        |> Map.take(["kind", "repo", "path", "command", "details"])
        |> inspect()
      end)

    last_error = prompt_state["last_error"] || prompt_state["reason"] || prompt_state[:reason]
    body = prompt.body || ""

    %{
      prompt
      | body: """
        #{body}

        ## Repair Instructions

        Continue from the current workspace state.
        Only fix the remaining unmet verifier items.
        Do not redo already satisfied work.

        Last runtime error:
        #{last_error || "n/a"}

        Remaining verifier failures:
        - #{failures}
        """
    }
  end

  defp handle_attempt_outcome({:retry, reason, failure, delay_ms}, ctx),
    do: maybe_schedule_retry(ctx, reason, failure, delay_ms)

  defp handle_attempt_outcome({:repair, report, reason, failure}, ctx),
    do: maybe_run_repair(ctx, report, reason, failure)

  defp handle_attempt_outcome(other, _ctx), do: other

  defp maybe_schedule_retry(ctx, reason, failure, delay_ms) do
    Runtime.mark_status(ctx.plan, ctx.prompt.num, "retry_scheduled", %{
      "failure_class" => FailureEnvelope.class_name(failure),
      "failure" => failure,
      "reason" => summarize_reason(reason),
      "retry_delay_ms" => delay_ms
    })

    if delay_ms > 0, do: Process.sleep(delay_ms)
    run_prompt_attempts(ctx.plan, ctx.prompt, ctx.skip_commit, :retry, ctx.attempt + 1)
  end

  defp maybe_run_repair(ctx, report, reason, failure) do
    Runtime.mark_status(ctx.plan, ctx.prompt.num, "repairing", %{
      "last_verifier" => report,
      "failure_class" => FailureEnvelope.class_name(failure),
      "failure" => failure,
      "last_error" => summarize_reason(reason)
    })

    run_prompt_attempts(
      ctx.plan,
      build_repair_prompt(ctx.prompt, %{
        "last_verifier" => report,
        "last_error" => summarize_reason(reason),
        "last_failure_class" => FailureEnvelope.class_name(failure)
      }),
      ctx.skip_commit,
      :repair,
      ctx.attempt + 1
    )
  end

  defp prompt_attempt_context(plan, prompt, skip_commit, mode, attempt) do
    prompt_metadata = prompt.metadata

    %{
      plan: plan,
      prompt: prompt,
      prompt_path: prompt_path(plan, prompt),
      llm:
        Config.llm_for_prompt(plan.config, prompt)
        |> Map.put(:attempt, attempt)
        |> Map.put(:mode, mode)
        |> Map.put(:prompt_id, prompt.num)
        |> Map.put(:prompt_metadata, prompt_metadata)
        |> Map.put(:simulation, Map.get(prompt_metadata, "simulate", %{}))
        |> Map.put(:repo_paths, repo_paths(plan)),
      skip_commit: skip_commit,
      mode: mode,
      attempt: attempt
    }
  end

  defp recovery_context(ctx, llm_meta, log_ctx) do
    %{
      renderer: renderer_for_config(ctx.plan.config),
      sinks: build_sinks(ctx.plan, log_ctx.log_io, log_ctx.events_file, ctx.llm),
      llm: ctx.llm,
      llm_meta: llm_meta,
      plan: ctx.plan,
      prompt: ctx.prompt,
      log_io: log_ctx.log_io
    }
  end

  defp fetch_prompt(plan, prompt_id) do
    case Prompts.get(plan, prompt_id) do
      nil -> {:error, {:prompt_not_found, prompt_id}}
      prompt -> {:ok, prompt}
    end
  end

  defp record_attempt_failure(ctx, reason) do
    Runtime.record_attempt_result(ctx.plan, ctx.prompt.num, ctx.attempt, %{
      "status" => "failed",
      "failure_class" => failure_class(reason),
      "failure" => FailureEnvelope.from_reason(reason),
      "reason" => summarize_reason(reason)
    })
  end

  defp failure_class(reason) do
    reason
    |> FailureEnvelope.from_reason()
    |> FailureEnvelope.class_name()
  end

  defp normalize_prompt_id(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.pad_leading(2, "0")
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

      not RecoveryPolicy.resume_allowed?(recovery.plan, recovery.prompt, result, attempt) ->
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
    map_get(data, :confirmation_source) ||
      if(run_started_args_present?(data),
        do: "codex_cli.run_started_args",
        else: "codex_cli.run_started"
      )
  end

  defp confirmation_model(data, metadata) do
    map_get(data, :confirmed_model) ||
      map_get(data, :model) ||
      map_get(metadata, :model) ||
      run_started_args_model(data)
  end

  defp confirmation_reasoning_effort(data, metadata) do
    map_get(data, :reasoning_effort) ||
      map_get(data, :confirmed_reasoning_effort) ||
      map_get(metadata, :reasoning_effort) ||
      map_get(metadata, :reasoningEffort) ||
      metadata_config_reasoning(metadata) ||
      run_started_args_reasoning(data)
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

  defp run_started_args_present?(data) do
    case map_get(data, :args) do
      args when is_list(args) -> args != []
      _ -> false
    end
  end

  defp run_started_args_model(data) do
    data
    |> run_started_args()
    |> option_value("--model")
  end

  defp run_started_args_reasoning(data) do
    data
    |> run_started_args()
    |> config_option_values()
    |> Enum.find_value(&config_reasoning_value/1)
  end

  defp run_started_args(data) do
    case map_get(data, :args) do
      args when is_list(args) -> Enum.map(args, &to_string/1)
      _ -> []
    end
  end

  defp option_value(args, flag) when is_list(args) and is_binary(flag) do
    args
    |> Enum.with_index()
    |> Enum.find_value(fn
      {^flag, idx} -> Enum.at(args, idx + 1)
      _ -> nil
    end)
  end

  defp config_option_values(args) when is_list(args) do
    args
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {"--config", idx} ->
        case Enum.at(args, idx + 1) do
          value when is_binary(value) and value != "" -> [value]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp config_reasoning_value(config_value) when is_binary(config_value) do
    case Regex.run(
           ~r/(?:^|[\s{,])(?:model_)?reasoning_effort\s*=\s*"?([A-Za-z0-9_-]+)"?/,
           config_value
         ) do
      [_, reasoning] -> reasoning
      _ -> nil
    end
  end

  defp config_reasoning_value(_config_value), do: nil

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

  defp maybe_print_provider_preflight(nil), do: :ok

  defp maybe_print_provider_preflight(%{
         provider: provider,
         lane: lane,
         cli_command: cli_command,
         cli_path_env: cli_path_env,
         core_profile_id: core_profile_id,
         sdk_available?: sdk_available?
       }) do
    IO.puts(
      "LLM provider preflight: provider=#{provider} lane=#{lane} cli=#{cli_command} env=#{cli_path_env} core_profile=#{core_profile_id} sdk_available=#{sdk_available?}"
    )
  end

  defp preflight_llm_provider(%{sdk: provider}) do
    # In tests and custom integrations, a custom llm_module may fully own provider setup.
    if llm_module() != PromptRunner.LLMFacade do
      {:ok, nil}
    else
      provider_runtime_info(provider)
    end
  end

  defp preflight_llm_provider(_), do: {:ok, nil}

  defp provider_runtime_info(provider) when is_atom(provider) do
    if provider == :simulated do
      {:ok,
       %{
         provider: :simulated,
         lane: :builtin,
         cli_command: "builtin",
         cli_path_env: "n/a",
         install_hint: "No external provider CLI is required.",
         core_profile_id: "simulated",
         available_lanes: [:builtin],
         sdk_available?: true
       }}
    else
      with {:ok, provider_def} <- ASM.Provider.resolve(provider),
           {:ok, provider_info} <- ASM.ProviderRegistry.provider_info(provider) do
        example_support = provider_def.example_support

        {:ok,
         %{
           provider: provider,
           lane: :core,
           cli_command: example_support.cli_command,
           cli_path_env: example_support.cli_path_env,
           install_hint: example_support.install_hint,
           core_profile_id: provider_info.core_profile_id,
           available_lanes: provider_info.available_lanes,
           sdk_available?: provider_info.sdk_available?
         }}
      end
    end
  end

  @doc false
  @spec check_provider_runtime(atom()) :: {:ok, map() | nil} | {:error, term()}
  def check_provider_runtime(:simulated), do: provider_runtime_info(:simulated)

  def check_provider_runtime(provider) when is_atom(provider) do
    case ASM.Provider.resolve(provider) do
      {:ok, _provider} -> provider_runtime_info(provider)
      {:error, _error} -> {:ok, nil}
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

  defp finalize_stream_result(stream_result, ctx) do
    report = Verifier.verify_prompt(ctx.plan, ctx.prompt)

    Runtime.record_attempt_result(ctx.plan, ctx.prompt.num, ctx.attempt, %{
      "status" => attempt_status(stream_result, report),
      "verifier" => report,
      "failure_class" => stream_failure_class(stream_result),
      "failure" => failure_for_stream_result(stream_result),
      "reason" => stream_reason(stream_result)
    })

    case RecoveryPolicy.final_action(ctx.plan, ctx.prompt, ctx.mode, stream_result, report) do
      {:complete, override?, failure} ->
        complete_prompt_attempt(ctx, report, override?, failure)

      {:provider_failed, reason, failure} ->
        fail_prompt_attempt(ctx, report, reason, failure)

      {:verification_failed, reason, failure} ->
        request_prompt_repair(ctx, report, reason, failure)

      {:retry, reason, failure, delay_ms} ->
        retry_prompt_attempt(ctx, report, reason, failure, delay_ms)

      {:repair, report, reason, failure} ->
        request_prompt_repair(ctx, report, reason, failure)
    end
  end

  defp complete_prompt_attempt(ctx, report, override?, failure) do
    commit_info =
      if ctx.skip_commit do
        {:skip, :no_commit}
      else
        commit_prompt(ctx.plan, ctx.prompt, ctx.llm)
      end

    Progress.mark_completed(ctx.plan, ctx.prompt.num, commit_info)

    Runtime.mark_status(ctx.plan, ctx.prompt.num, "completed", %{
      "commit_info" => commit_info,
      "last_verifier" => report,
      "failure" => failure
    })

    emit_observer(ctx.plan, %{
      type: :prompt_completed,
      prompt: ctx.prompt,
      commit_info: commit_info
    })

    if override? do
      IO.puts(UI.yellow("Provider reported an error, but verification passed."))
    end

    print_completion_success(ctx.plan, ctx.prompt)
    :ok
  end

  defp fail_prompt_attempt(ctx, report, reason, failure) do
    Progress.mark_failed(ctx.plan, ctx.prompt.num)

    Runtime.mark_status(ctx.plan, ctx.prompt.num, "failed", %{
      "last_verifier" => report,
      "failure_class" => FailureEnvelope.class_name(failure),
      "failure" => failure,
      "reason" => summarize_reason(reason)
    })

    emit_observer(ctx.plan, %{type: :prompt_failed, prompt: ctx.prompt, reason: reason})
    return_error(ctx.plan, ctx.prompt.num, reason, false)
  end

  defp request_prompt_repair(ctx, report, reason, failure) do
    Progress.mark_failed(ctx.plan, ctx.prompt.num)

    Runtime.mark_status(ctx.plan, ctx.prompt.num, "verification_failed", %{
      "last_verifier" => report,
      "failure_class" => FailureEnvelope.class_name(failure),
      "failure" => failure,
      "reason" => summarize_reason(reason)
    })

    emit_observer(ctx.plan, %{type: :prompt_failed, prompt: ctx.prompt, reason: reason})

    IO.puts(UI.red("Verification failed for prompt #{ctx.prompt.num}"))
    {:repair, report, reason, failure}
  end

  defp retry_prompt_attempt(ctx, report, reason, failure, delay_ms) do
    Progress.mark_failed(ctx.plan, ctx.prompt.num)

    Runtime.mark_status(ctx.plan, ctx.prompt.num, "failed", %{
      "last_verifier" => report,
      "failure_class" => FailureEnvelope.class_name(failure),
      "failure" => failure,
      "reason" => summarize_reason(reason)
    })

    IO.puts(
      UI.yellow(
        "Retrying prompt #{ctx.prompt.num} after #{FailureEnvelope.class_name(failure)}..."
      )
    )

    {:retry, reason, failure, delay_ms}
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

  defp repo_paths(%Plan{config: %{target_repos: repos}}) when is_list(repos) do
    Enum.into(repos, %{}, fn repo -> {repo.name, repo.path} end)
  end

  defp repo_paths(_plan), do: %{}

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
