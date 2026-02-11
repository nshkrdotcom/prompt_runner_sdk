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

          IO.puts("")
          IO.puts(UI.blue(String.duplicate("=", 60)))
          IO.puts(UI.bold("Prompt #{num}: #{prompt.name}"))
          IO.puts(UI.blue(String.duplicate("=", 60)))
          IO.puts("")
          IO.puts("Prompt: #{prompt_path}")
          IO.puts("Project: #{llm.cwd}")
          IO.puts("LLM: #{llm.sdk} model=#{llm.model}")
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

    renderer = renderer_for_config(config)
    sinks = build_sinks(config, log_io, events_file)

    render_result = safe_render_stream(stream, renderer, sinks)
    callback_result = Process.get(:prompt_runner_stream_result, :ok)
    Process.delete(:prompt_runner_stream_result)

    result = resolve_stream_result(render_result, callback_result)

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

  defp build_sinks(config, log_io, events_file) do
    sinks = [
      {TTYSink, []},
      {FileSink, [io: log_io]},
      {CallbackSink, [callback: &error_tracking_callback/2]}
    ]

    if config.events_mode != :off do
      sinks ++ [{JSONLSink, [path: events_file, mode: config.events_mode]}]
    else
      sinks
    end
  end

  defp error_tracking_callback(event, _iodata) do
    case event.type do
      type when type in [:error_occurred, :run_failed] ->
        msg = get_in(event, [:data, :error_message]) || "unknown error"
        Process.put(:prompt_runner_stream_result, {:error, msg})

      _ ->
        :ok
    end
  end

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
