defmodule PromptRunner.Runner do
  @moduledoc false

  alias PromptRunner.CommitMessages
  alias PromptRunner.Config
  alias PromptRunner.Git
  alias PromptRunner.Progress
  alias PromptRunner.Prompts
  alias PromptRunner.StreamRenderer
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
    IO.puts("   LLM SDK: #{llm.sdk}")
    IO.puts("   - model: #{llm.model}")
    IO.puts("   - cwd: #{llm.cwd}")

    if llm.sdk == :claude do
      tools_label =
        if is_list(llm.allowed_tools) do
          Enum.join(llm.allowed_tools, ", ")
        else
          "default"
        end

      IO.puts("   - tools: #{tools_label}")
      IO.puts("   - permission_mode: #{llm.permission_mode}")
    else
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

        Enum.each(repos, fn repo_name ->
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
        Enum.each(repos, &print_repo_commit_message(config, prompt, &1))
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

          {:ok, log_io} = File.open(log_file, [:write, :binary])
          {:ok, events_io} = File.open(events_file, [:write, :binary])
          loggers = %{text_io: log_io, events_io: events_io, events_mode: config.events_mode}
          log_config = %{mode: config.log_mode, meta: config.log_meta}

          llm_module().start_stream(llm, prompt_content)
          |> handle_stream_result(
            config,
            prompt,
            prompt_path,
            llm,
            loggers,
            log_config,
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
         loggers,
         log_config,
         skip_commit
       ) do
    try do
      write_session_header(loggers, config, llm, llm_meta, prompt_path)

      result =
        StreamRenderer.stream(stream, loggers, %{prompt: prompt, llm: llm_meta}, log_config)

      StreamRenderer.emit_line(loggers, "")
      finalize_stream_result(result, config, prompt, llm, skip_commit)
    after
      close_llm.()
      File.close(loggers.text_io)
      File.close(loggers.events_io)
    end
  end

  defp handle_stream_result(
         {:error, reason},
         config,
         prompt,
         _prompt_path,
         _llm,
         loggers,
         _log_config,
         _skip_commit
       ) do
    File.close(loggers.text_io)
    File.close(loggers.events_io)
    return_error(config, prompt.num, {:start_failed, reason})
  end

  defp return_error(config, num, reason) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    Progress.mark_failed(config, num)
    {:error, reason}
  end

  defp write_session_header(loggers, config, llm, llm_meta, prompt_path) do
    if config.log_mode == :compact do
      tools_label =
        if llm.sdk == :claude and is_list(llm.allowed_tools) do
          Enum.join(llm.allowed_tools, ",")
        else
          "n/a"
        end

      StreamRenderer.emit_line(
        loggers,
        "Session: sdk=#{llm_meta.sdk} model=#{llm_meta.model} tools=[#{tools_label}] cwd=#{llm_meta.cwd}"
      )
    else
      StreamRenderer.emit_line(loggers, "Session: #{inspect(llm_meta)}")
    end

    StreamRenderer.emit_line(loggers, "Prompt: #{prompt_path}")
    StreamRenderer.emit_line(loggers, "Project: #{llm.cwd}")

    if config.log_mode == :compact do
      StreamRenderer.emit_line(loggers, StreamRenderer.compact_legend_line())
    else
      StreamRenderer.emit_line(loggers, "")
    end
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
      Git.commit_single_repo(config, prompt.num)
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
        Enum.map(repos, fn repo_name ->
          path = get_repo_path(config, repo_name)
          {repo_name, path || config.project_dir}
        end)
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
