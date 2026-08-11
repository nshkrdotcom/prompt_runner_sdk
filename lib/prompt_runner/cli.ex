defmodule PromptRunner.CLI do
  @moduledoc """
  Command-line entrypoint for the Prompt Runner packet workflow.
  """

  alias ExecutionPlane.Process.Containment.SystemdUser
  alias PromptRunner
  alias PromptRunner.Capabilities
  alias PromptRunner.CLI.Control, as: CLIControl
  alias PromptRunner.Packet
  alias PromptRunner.PacketLint
  alias PromptRunner.Packets
  alias PromptRunner.Profile
  alias PromptRunner.RecoveryConfig
  alias PromptRunner.Runner
  alias PromptRunner.Template
  alias PromptRunner.UI
  alias PromptRunner.Verifier
  alias PromptRunner.Watch
  alias PromptRunner.Workspace
  alias PromptRunner.Workspace.Manifest, as: WorkspaceManifest
  alias PromptRunner.Workspace.Plan, as: WorkspacePlan
  alias PromptRunner.Workspace.Watch, as: WorkspaceWatch

  @service_env_names ~w(
    HOME USER LOGNAME PATH SHELL LANG LC_ALL TERM SSH_AUTH_SOCK
    XDG_CONFIG_HOME XDG_CACHE_HOME XDG_DATA_HOME XDG_STATE_HOME XDG_RUNTIME_DIR
    MIX_HOME HEX_HOME REBAR_CACHE_DIR ASDF_DIR ASDF_DATA_DIR CODEX_HOME
    ANTHROPIC_API_KEY OPENAI_API_KEY
  )

  # `plan` and `run` share one switch surface deliberately. When they did not,
  # `plan` parsed nothing and passed nothing to `PromptRunner.plan/2`, so
  # `prompt_runner plan --provider X` reported the packet's provider regardless
  # and could not be used to check what an override would actually do.
  # `--continue` is deliberately absent: it resumes after the last *completed*
  # prompt and therefore steps over an earlier one that failed, which is a
  # documented behaviour rather than a CLI affordance. `--remaining` is the one
  # a resume actually wants.
  @run_switches [
    all: :boolean,
    remaining: :boolean,
    new_run: :boolean,
    verify_first: :boolean,
    keep_going: :boolean,
    phase: :integer,
    from: :string,
    through: :string,
    workspace: :string,
    packet: :string,
    detach: :boolean,
    no_commit: :boolean,
    dry_run: :boolean,
    provider: :string,
    model: :string,
    log_mode: :string,
    log_meta: :string,
    events_mode: :string,
    tool_output: :string,
    thinking: :string,
    diff: :string,
    cli_confirmation: :string,
    runtime_store: :string,
    committer: :string,
    skip_preflight: :boolean
  ]

  @spec main(list()) :: :ok | no_return()
  def main(args \\ System.argv()) do
    args
    |> parse_command()
    |> dispatch_command()
  end

  defp run_init(rest) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [default_profile: :string],
        aliases: [p: :default_profile]
      )

    {:ok, paths} = Profile.init(default_profile: opts[:default_profile])
    IO.puts(UI.green("Prompt Runner initialized"))
    IO.puts("  config: #{paths.config_file}")
    IO.puts("  profile: #{paths.profile_file}")
    IO.puts("  simulated profile: #{paths.simulated_profile_file}")
    IO.puts("  templates: #{paths.templates_dir}")
    IO.puts("  default template: #{paths.default_template_file}")
    IO.puts("  from-adr template: #{paths.from_adr_template_file}")
    :ok
  end

  defp run_profile_new(name, rest) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          provider: :string,
          model: :string,
          reasoning: :string,
          permission: :string,
          tools: :string,
          prompt_template: :string,
          cli_confirmation: :string,
          resume_attempts: :integer,
          retry_attempts: :integer,
          retry_base_delay_ms: :integer,
          retry_max_delay_ms: :integer,
          retry_jitter: :boolean,
          auto_repair: :boolean,
          repair_attempts: :integer
        ]
      )

    attrs =
      %{}
      |> maybe_put("provider", opts[:provider])
      |> maybe_put("model", opts[:model])
      |> maybe_put("reasoning_effort", opts[:reasoning])
      |> maybe_put("permission_mode", opts[:permission])
      |> maybe_put("cli_confirmation", opts[:cli_confirmation])
      |> maybe_put("prompt_template", opts[:prompt_template])
      |> maybe_put("recovery", recovery_attrs(opts))
      |> maybe_put("allowed_tools", parse_csv(opts[:tools]))

    case Profile.create(name, attrs) do
      {:ok, profile} ->
        IO.puts(UI.green("Created profile #{profile.name}"))
        IO.puts("  path: #{profile.path}")
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_profile_list(_rest) do
    {:ok, profiles} = Profile.list()
    Enum.each(profiles, &IO.puts(&1))
    :ok
  end

  defp run_template_list(rest) do
    packet_dir =
      case rest do
        [candidate | _] ->
          if File.dir?(candidate), do: candidate, else: nil

        _ ->
          nil
      end

    {:ok, templates} = Template.list(packet_dir)

    Enum.each(templates, fn template ->
      location =
        case template.source do
          :builtin -> "builtin"
          :home -> template.path
          :packet -> template.path
        end

      IO.puts("#{template.name}\t#{template.source}\t#{location}")
    end)

    :ok
  end

  defp run_packet_new(name, rest) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          root: :string,
          profile: :string,
          repo: :keep,
          default_repo: :string,
          provider: :string,
          model: :string,
          reasoning: :string,
          permission: :string,
          prompt_template: :string,
          resume_attempts: :integer,
          retry_attempts: :integer,
          retry_base_delay_ms: :integer,
          retry_max_delay_ms: :integer,
          retry_jitter: :boolean,
          auto_repair: :boolean,
          repair_attempts: :integer,
          cli_confirmation: :string
        ],
        aliases: [p: :profile]
      )

    case parse_repo_specs(opts[:repo]) do
      {:ok, repo_specs} ->
        packet_opts =
          []
          |> maybe_put(:root, opts[:root])
          |> maybe_put(:profile, opts[:profile])
          |> maybe_put(:repos, repo_specs)
          |> maybe_put(:default_repo, opts[:default_repo])
          |> maybe_put(:provider, opts[:provider])
          |> maybe_put(:model, opts[:model])
          |> maybe_put(:reasoning_effort, opts[:reasoning])
          |> maybe_put(:permission_mode, opts[:permission])
          |> maybe_put(:prompt_template, opts[:prompt_template])
          |> maybe_put(:resume_attempts, opts[:resume_attempts])
          |> maybe_put(:retry_attempts, opts[:retry_attempts])
          |> maybe_put(:retry_base_delay_ms, opts[:retry_base_delay_ms])
          |> maybe_put(:retry_max_delay_ms, opts[:retry_max_delay_ms])
          |> maybe_put(:retry_jitter, opts[:retry_jitter])
          |> maybe_put(:auto_repair, opts[:auto_repair])
          |> maybe_put(:repair_attempts, opts[:repair_attempts])
          |> maybe_put(:cli_confirmation, opts[:cli_confirmation])

        case Packet.new(name, packet_opts) do
          {:ok, packet} ->
            IO.puts(UI.green("Created packet #{packet.name}"))
            IO.puts("  root: #{packet.root}")
            IO.puts("  manifest: #{packet.manifest_path}")
            :ok

          {:error, reason} ->
            handle_error(reason)
        end

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_packet_doctor(rest) do
    packet_dir = packet_dir(rest)

    case Packet.doctor(packet_dir) do
      {:ok, report} ->
        IO.puts(Jason.encode!(report, pretty: true))
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_packet_preflight(rest) do
    packet_dir = packet_dir(rest)

    case Packet.preflight(packet_dir) do
      {:ok, report} ->
        IO.puts(Jason.encode!(report, pretty: true))
        :ok

      {:error, {:preflight_failed, report}} ->
        IO.puts(Jason.encode!(report, pretty: true))
        System.halt(1)

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_packet_lint(rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest, switches: [strict: :boolean, json: :boolean])

    packet_dir = packet_dir(remaining)
    lint_opts = maybe_put([], :strict, opts[:strict])

    case PacketLint.lint(packet_dir, lint_opts) do
      {:ok, report} -> report_lint(report, opts[:json] == true)
      {:error, reason} -> handle_error(reason)
    end
  end

  defp report_lint(report, true) do
    IO.puts(Jason.encode!(report, pretty: true))
    lint_exit(report)
  end

  defp report_lint(report, false) do
    IO.puts("")
    IO.puts(UI.bold("Packet lint: #{report.packet}"))
    IO.puts(UI.cyan(report.root))
    IO.puts("")

    case report.findings do
      [] -> IO.puts("  no authoring hazards found")
      findings -> Enum.each(findings, &print_lint_finding/1)
    end

    IO.puts("")
    IO.puts(lint_summary(report))
    lint_exit(report)
  end

  defp print_lint_finding(finding) do
    IO.puts("  #{lint_severity_label(finding.severity)} #{lint_location(finding)}")
    IO.puts("          #{finding.message}")
  end

  defp lint_severity_label("error"), do: UI.red("ERROR  ")
  defp lint_severity_label(_severity), do: UI.yellow("WARNING")

  defp lint_location(finding) do
    "#{finding.file || "(packet)"}  #{finding.kind}"
  end

  defp lint_summary(report) do
    summary = "#{pluralize(report.errors, "error")}, #{pluralize(report.warnings, "warning")}"

    if report.pass?, do: UI.green(summary), else: UI.red(summary)
  end

  defp pluralize(1, noun), do: "1 #{noun}"
  defp pluralize(count, noun), do: "#{count} #{noun}s"

  @spec lint_exit(map()) :: :ok | no_return()
  defp lint_exit(%{pass?: true}), do: :ok
  defp lint_exit(_report), do: System.halt(1)

  defp run_packet_explain(rest) do
    packet_dir = packet_dir(rest)

    case Packet.explain(packet_dir) do
      {:ok, report} ->
        IO.puts(Jason.encode!(report, pretty: true))
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_repo_add(name, path, rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [packet: :string, default: :boolean]
      )

    packet_dir = packet_dir(remaining, opts[:packet])

    case Packet.add_repo(packet_dir, name, path, default: opts[:default]) do
      {:ok, packet} ->
        IO.puts(UI.green("Updated packet #{packet.name}"))
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_prompt_new(id, rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          packet: :string,
          phase: :integer,
          name: :string,
          targets: :string,
          commit: :string,
          template: :string
        ]
      )

    packet_dir = packet_dir(remaining, opts[:packet])

    attrs =
      %{}
      |> maybe_put("id", id)
      |> maybe_put("phase", opts[:phase])
      |> maybe_put("name", opts[:name])
      |> maybe_put("targets", parse_csv(opts[:targets]))
      |> maybe_put("commit", opts[:commit])
      |> maybe_put("template", opts[:template])

    case Packets.create_prompt(packet_dir, attrs) do
      {:ok, path} ->
        IO.puts(UI.green("Created prompt #{id}"))
        IO.puts("  path: #{path}")
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_checklist_sync(rest) do
    packet_dir = packet_dir(rest)

    case Packets.sync_checklists(packet_dir) do
      {:ok, %{paths: paths, warnings: warnings}} ->
        IO.puts(UI.green("Synchronized checklists"))
        Enum.each(paths, &IO.puts("  #{&1}"))

        Enum.each(warnings, fn warning ->
          IO.puts(
            UI.yellow(
              "WARNING: prompt #{warning.prompt_id} (#{warning.file}) has no verification items yet"
            )
          )
        end)

        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_list(rest) do
    packet_dir = packet_dir(rest)

    case PromptRunner.plan(packet_dir, interface: :cli) do
      {:ok, plan} ->
        Runner.list_plan(plan)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_plan(rest) do
    case parse_run_options(rest) do
      {:ok, opts, remaining} ->
        {packet_dir, prompt_ids} = packet_and_prompt_ids(remaining, opts[:packet])

        case cli_plan(packet_dir, opts) do
          {:ok, plan} ->
            print_selected_plan(plan, opts, prompt_ids)

          {:error, reason} ->
            handle_error(reason)
        end

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp print_selected_plan(plan, opts, prompt_ids) do
    selection =
      if selection_requested?(opts, prompt_ids),
        do: Runner.select_targets(plan, opts, prompt_ids),
        else: {:ok, Enum.map(plan.prompts, & &1.num)}

    case selection do
      {:ok, targets} ->
        print_plan_summary(plan, targets)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp selection_requested?(opts, prompt_ids) do
    prompt_ids != [] or
      Enum.any?(~w(all remaining phase from through)a, &(not is_nil(opts[&1])))
  end

  defp run_run(rest) do
    with {:ok, opts, remaining} <- parse_run_options(rest),
         {packet_dir, prompt_ids} = packet_and_prompt_ids(remaining, opts[:packet]),
         {:ok, plan} <- cli_plan(packet_dir, opts) do
      execute_cli_run(plan, opts, prompt_ids)
    else
      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_verify(rest) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest, strict: [workspace: :string, packet: :string, json: :boolean])

    with true <- invalid == [] || {:error, {:invalid_options, invalid}},
         {packet_dir, prompt_ids} = packet_and_prompt_ids(remaining, opts[:packet]),
         {:ok, plan} <- cli_plan(packet_dir, opts),
         :ok <- validate_verify_prompt_ids(plan, prompt_ids),
         {:ok, reports} <-
           Verifier.verify(plan, if(prompt_ids == [], do: [], else: [prompts: prompt_ids])) do
      result = verify_result(reports)
      print_verify_result(result, opts[:json] == true)

      cond do
        result.faults > 0 -> handle_error({:verification_faults, result.faults})
        result.failures > 0 -> handle_error({:verification_failures, result.failures})
        true -> :ok
      end
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp validate_verify_prompt_ids(_plan, []), do: :ok

  defp validate_verify_prompt_ids(plan, prompt_ids) do
    known = Enum.map(plan.prompts, & &1.num)

    case prompt_ids -- known do
      [] -> :ok
      unknown -> {:error, {:unknown_prompts, unknown, known}}
    end
  end

  defp verify_result(reports) do
    failures = Enum.count(reports, &(not &1.pass? and not Verifier.fault?(&1)))
    faults = Enum.count(reports, &Verifier.fault?/1)

    %{
      schema: "prompt_runner.verify/v1",
      pass?: failures == 0 and faults == 0,
      prompts: length(reports),
      failures: failures,
      faults: faults,
      reports: reports
    }
  end

  defp print_verify_result(result, true), do: IO.puts(Jason.encode!(result, pretty: true))

  defp print_verify_result(result, false) do
    IO.puts(
      "Verified #{result.prompts} prompt(s): #{result.failures} failures, #{result.faults} faults"
    )
  end

  defp cli_plan(packet_dir, opts) do
    case opts[:workspace] do
      nil ->
        PromptRunner.plan(packet_dir, cli_opts(opts))

      manifest_path ->
        case Workspace.plan(manifest_path, packet_dir, cli_opts(opts)) do
          {:ok, %{runner: plan}} -> {:ok, plan}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp execute_cli_run(plan, opts, prompt_ids) do
    cli_run_opts =
      opts
      |> cli_opts()
      |> Keyword.put(:run, true)
      |> maybe_put(
        :all,
        opts[:all] || (prompt_ids == [] and not truthy?(opts[:remaining]))
      )
      |> maybe_put(:remaining, opts[:remaining])
      |> maybe_put(:verify_first, opts[:verify_first])
      |> maybe_put(:keep_going, opts[:keep_going])
      |> maybe_put(:phase, opts[:phase])
      |> maybe_put(:from, normalize_optional_id(opts[:from]))
      |> maybe_put(:through, normalize_optional_id(opts[:through]))
      |> maybe_put(:no_commit, opts[:no_commit])
      |> maybe_put(:dry_run, opts[:dry_run])

    case Runner.execute_plan(plan, cli_run_opts, prompt_ids) do
      :ok -> :ok
      {:error, reason} -> handle_error(reason)
    end
  end

  @doc false
  @spec parse_run_options([String.t()]) ::
          {:ok, keyword(), [String.t()]} | {:error, {:invalid_options, list()}}
  def parse_run_options(rest) when is_list(rest) do
    case OptionParser.parse(rest, strict: @run_switches) do
      {opts, remaining, []} -> {:ok, opts, remaining}
      {_opts, _remaining, invalid} -> {:error, {:invalid_options, invalid}}
    end
  end

  defp run_repair(rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [packet: :string, no_commit: :boolean]
      )

    case remaining do
      [prompt_id] ->
        packet_dir = packet_dir([], opts[:packet])

        case PromptRunner.repair(packet_dir,
               prompt: prompt_id,
               interface: :cli,
               no_commit: opts[:no_commit]
             ) do
          {:ok, _run} -> :ok
          {:error, reason} -> handle_error(reason)
        end

      _ ->
        handle_error(:missing_prompt_id)
    end
  end

  defp run_status(rest) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest, strict: [workspace: :string, packet: :string, json: :boolean])

    if invalid != [], do: handle_error({:invalid_options, invalid})

    result =
      case opts[:workspace] do
        nil -> PromptRunner.status(packet_dir(remaining, opts[:packet]))
        manifest_path -> Workspace.status(manifest_path)
      end

    case result do
      {:ok, status} ->
        IO.puts(Jason.encode!(status, pretty: opts[:json] != true))
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_watch(rest) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [
          workspace: :string,
          packet: :string,
          interval: :integer,
          every: :string,
          for: :string,
          once: :boolean,
          json: :boolean,
          require_progress: :boolean,
          require_running: :boolean,
          progress_timeout: :string
        ]
      )

    if invalid != [], do: handle_error({:invalid_options, invalid})

    case opts[:workspace] do
      nil -> run_packet_watch(remaining, opts)
      manifest_path -> run_workspace_watch(manifest_path, opts)
    end
  end

  defp run_packet_watch(remaining, opts) do
    case Watch.run(packet_dir(remaining, opts[:packet]), opts) do
      :ok -> :ok
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_workspace_watch(manifest_path, opts) do
    watch_opts = workspace_watch_options(opts)

    case WorkspaceWatch.run(manifest_path, watch_opts) do
      {:ok, report} ->
        IO.puts(Jason.encode!(report, pretty: opts[:json] != true))
        :ok

      {:error, {:workspace_watch_unhealthy, report} = reason} ->
        if opts[:json] == true do
          IO.puts(Jason.encode!(report))
          System.halt(1)
        else
          handle_error(reason)
        end

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp workspace_watch_options(opts) do
    once? = opts[:once] == true

    [
      duration_seconds: if(once?, do: 1, else: parse_duration!(opts[:for] || "240m")),
      interval_seconds: if(once?, do: 1, else: parse_duration!(opts[:every] || "10m")),
      require_progress: opts[:require_progress] == true,
      require_running: opts[:require_running] == true,
      progress_timeout_seconds: parse_duration!(opts[:progress_timeout] || "60m"),
      json: opts[:json] == true
    ]
  end

  defp parse_duration!(value) when is_binary(value) do
    case Regex.run(~r/\A(\d+)(s|m|h)\z/, String.trim(value), capture: :all_but_first) do
      [amount, "s"] -> String.to_integer(amount)
      [amount, "m"] -> String.to_integer(amount) * 60
      [amount, "h"] -> String.to_integer(amount) * 3_600
      _other -> handle_error({:invalid_duration, value})
    end
  end

  defp run_control(["status" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest, strict: [json: :boolean, workspace: :string, packet: :string])

    with :ok <- valid_options(invalid),
         {:ok, root} <- live_control_root(opts, remaining) do
      control_result(CLIControl.status(root, opts))
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(["view" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [
          log_mode: :string,
          tool_output: :string,
          diff: :string,
          workspace: :string,
          packet: :string
        ]
      )

    with :ok <- valid_options(invalid),
         {:ok, root} <- live_control_root(opts, remaining) do
      control_result(CLIControl.view(root, opts))
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(["steer" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [author: :string, workspace: :string, packet: :string]
      )

    with :ok <- valid_options(invalid),
         {:ok, root, words} <- steer_control_target(opts, remaining) do
      control_result(CLIControl.steer(root, words, opts))
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(["amend" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [
          add_file: :string,
          add_command: :string,
          add_path: :string,
          reason: :string,
          persist: :boolean,
          workspace: :string,
          packet: :string
        ]
      )

    case valid_options(invalid) do
      :ok ->
        with_control_prompt_target(
          opts,
          remaining,
          &control_result(CLIControl.amend(&1, &2, opts))
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_control(["relax" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [
          drop: :string,
          reason: :string,
          confirm: :boolean,
          persist: :boolean,
          workspace: :string,
          packet: :string
        ]
      )

    case valid_options(invalid) do
      :ok ->
        with_control_prompt_target(
          opts,
          remaining,
          &control_result(CLIControl.relax(&1, &2, opts))
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_control(["contract" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [json: :boolean, workspace: :string, packet: :string]
      )

    case valid_options(invalid) do
      :ok ->
        with_control_prompt_target(
          opts,
          remaining,
          &control_result(CLIControl.contract(&1, &2, opts))
        )

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_control(["log" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [follow: :boolean, json: :boolean, workspace: :string, packet: :string]
      )

    with :ok <- valid_options(invalid),
         {:ok, root} <- live_control_root(opts, remaining) do
      control_result(CLIControl.log(root, opts))
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(["events" | rest]) do
    {opts, remaining, invalid} =
      OptionParser.parse(rest,
        strict: [json: :boolean, from: :string, workspace: :string, packet: :string]
      )

    from = if opts[:from] == "current", do: :current, else: :start

    with :ok <- valid_options(invalid),
         {:ok, root} <- live_control_root(opts, remaining) do
      control_result(CLIControl.watch(root, Keyword.put(opts, :from, from)))
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(_rest), do: handle_error(:unknown_command)

  defp valid_options([]), do: :ok
  defp valid_options(invalid), do: {:error, {:invalid_options, invalid}}

  defp live_control_root(opts, remaining) do
    case opts[:workspace] do
      manifest when is_binary(manifest) ->
        if remaining == [] and is_nil(opts[:packet]) do
          Workspace.control_root(manifest)
        else
          {:error, {:unexpected_control_target, remaining, opts[:packet]}}
        end

      _other ->
        control_packet_root(opts[:packet], remaining)
    end
  end

  defp control_packet_root(explicit, []) when is_binary(explicit), do: {:ok, explicit}
  defp control_packet_root(nil, []), do: {:ok, File.cwd!()}
  defp control_packet_root(nil, [packet]), do: {:ok, packet}

  defp control_packet_root(explicit, remaining),
    do: {:error, {:unexpected_control_target, remaining, explicit}}

  defp steer_control_target(opts, remaining) do
    case opts[:workspace] do
      manifest when is_binary(manifest) ->
        with true <-
               is_nil(opts[:packet]) || {:error, {:unexpected_control_target, [], opts[:packet]}},
             {:ok, root} <- Workspace.control_root(manifest) do
          {:ok, root, remaining}
        end

      _other ->
        steer_packet_target(opts[:packet], remaining, opts)
    end
  end

  defp steer_packet_target(packet, words, _opts) when is_binary(packet),
    do: {:ok, packet, words}

  defp steer_packet_target(nil, [], _opts), do: {:error, :empty_steer}

  defp steer_packet_target(nil, [first | words], _opts) do
    if File.dir?(first),
      do: {:ok, first, words},
      else: {:ok, File.cwd!(), [first | words]}
  end

  defp with_control_prompt_target(opts, remaining, fun) do
    case opts[:workspace] do
      manifest when is_binary(manifest) ->
        with packet when is_binary(packet) <- opts[:packet] || {:error, :missing_packet},
             [prompt_id] <- remaining,
             {:ok, %{runner: plan}} <- Workspace.plan(manifest, packet) do
          fun.(plan, normalize_id(prompt_id))
        else
          {:error, reason} -> handle_error(reason)
          arguments when is_list(arguments) -> handle_error({:expected_one_prompt_id, arguments})
        end

      _other ->
        case {opts[:packet], remaining} do
          {packet, [prompt_id]} when is_binary(packet) ->
            fun.(packet, normalize_id(prompt_id))

          {nil, arguments} ->
            with_prompt_target(arguments, fun)

          {packet, arguments} ->
            handle_error({:unexpected_control_target, arguments, packet})
        end
    end
  end

  defp control_result(:ok), do: :ok
  defp control_result({:error, :no_run}), do: handle_error(:no_run)
  defp control_result({:error, :empty_steer}), do: handle_error(:empty_steer)
  defp control_result({:error, :reason_required}), do: handle_error(:reason_required)

  defp control_result({:error, :confirmation_required}),
    do: handle_error(:confirmation_required)

  defp control_result({:error, :no_amendment}), do: handle_error(:no_amendment)
  defp control_result({:error, :no_relaxation}), do: handle_error(:no_relaxation)

  defp control_result({:error, reason}), do: handle_error(reason)

  # `control amend PACKET 03 ...` and `control amend 03 ...` both have to work,
  # and only the filesystem can tell a packet directory from a prompt id.
  defp with_prompt_target([packet, prompt_id | _rest], fun) do
    if File.dir?(packet) do
      fun.(packet, normalize_id(prompt_id))
    else
      fun.(File.cwd!(), normalize_id(packet))
    end
  end

  defp with_prompt_target([only], fun) do
    if File.dir?(only),
      do: handle_error(:missing_prompt_id),
      else: fun.(File.cwd!(), normalize_id(only))
  end

  defp with_prompt_target(_remaining, _fun), do: handle_error(:missing_prompt_id)

  defp normalize_id(id), do: id |> String.trim() |> String.pad_leading(2, "0")

  defp packet_dir([], explicit), do: explicit || File.cwd!()
  defp packet_dir([candidate | _rest], nil), do: candidate
  defp packet_dir(_remaining, explicit), do: explicit

  defp packet_dir(remaining), do: packet_dir(remaining, nil)

  defp packet_and_prompt_ids(remaining, explicit_packet)

  defp packet_and_prompt_ids(remaining, explicit_packet) when is_binary(explicit_packet) do
    prompt_ids = Enum.reject(remaining, &String.starts_with?(&1, "-"))
    {explicit_packet, normalize_prompt_ids(prompt_ids)}
  end

  defp packet_and_prompt_ids([], nil), do: {File.cwd!(), []}

  defp packet_and_prompt_ids([first | rest], nil) do
    if String.starts_with?(first, "-") do
      {File.cwd!(), []}
    else
      prompt_ids = Enum.reject(rest, &String.starts_with?(&1, "-"))

      if File.dir?(first) do
        {first, normalize_prompt_ids(prompt_ids)}
      else
        {File.cwd!(), normalize_prompt_ids([first | prompt_ids])}
      end
    end
  end

  defp parse_command(["init" | rest]), do: {:init, rest}
  defp parse_command(["--version" | rest]), do: {:version, rest}
  defp parse_command(["-v" | rest]), do: {:version, rest}
  defp parse_command(["version" | rest]), do: {:version, rest}
  defp parse_command(["capabilities" | rest]), do: {:capabilities, rest}
  defp parse_command(["workspace", "plan" | rest]), do: {:workspace_plan, rest}
  defp parse_command(["workspace", "prepare" | rest]), do: {:workspace_prepare, rest}
  defp parse_command(["workspace", "doctor" | rest]), do: {:workspace_doctor, rest}
  defp parse_command(["workspace", "import-state" | rest]), do: {:workspace_import_state, rest}
  defp parse_command(["profile", "new", name | rest]), do: {:profile_new, name, rest}
  defp parse_command(["profile", "list" | rest]), do: {:profile_list, rest}
  defp parse_command(["template", "list" | rest]), do: {:template_list, rest}
  defp parse_command(["packet", "new", name | rest]), do: {:packet_new, name, rest}
  defp parse_command(["packet", "doctor" | rest]), do: {:packet_doctor, rest}
  defp parse_command(["packet", "preflight" | rest]), do: {:packet_preflight, rest}
  defp parse_command(["packet", "explain" | rest]), do: {:packet_explain, rest}
  defp parse_command(["packet", "lint" | rest]), do: {:packet_lint, rest}
  defp parse_command(["repo", "add", name, path | rest]), do: {:repo_add, name, path, rest}
  defp parse_command(["prompt", "new", id | rest]), do: {:prompt_new, id, rest}
  defp parse_command(["checklist", "sync" | rest]), do: {:checklist_sync, rest}
  defp parse_command(["list" | rest]), do: {:list, rest}
  defp parse_command(["plan" | rest]), do: {:plan, rest}
  defp parse_command(["run" | rest]), do: {:run, rest}
  defp parse_command(["verify" | rest]), do: {:verify, rest}
  defp parse_command(["start" | rest]), do: {:start, rest}
  defp parse_command(["stop" | rest]), do: {:stop, rest}
  defp parse_command(["repair" | rest]), do: {:repair, rest}
  defp parse_command(["status" | rest]), do: {:status, rest}
  defp parse_command(["watch" | rest]), do: {:watch, rest}
  defp parse_command(["control" | rest]), do: {:control, rest}
  defp parse_command(["help" | _rest]), do: :help
  defp parse_command(["--help" | _rest]), do: :help
  defp parse_command(["-h" | _rest]), do: :help
  defp parse_command([]), do: :help
  defp parse_command(_args), do: :unknown

  defp dispatch_command({:init, rest}), do: run_init(rest)
  defp dispatch_command({:version, rest}), do: run_version(rest)
  defp dispatch_command({:capabilities, rest}), do: run_capabilities(rest)
  defp dispatch_command({:workspace_plan, rest}), do: run_workspace_plan(rest)
  defp dispatch_command({:workspace_prepare, rest}), do: run_workspace_prepare(rest)
  defp dispatch_command({:workspace_doctor, rest}), do: run_workspace_doctor(rest)
  defp dispatch_command({:workspace_import_state, rest}), do: run_workspace_import_state(rest)
  defp dispatch_command({:profile_new, name, rest}), do: run_profile_new(name, rest)
  defp dispatch_command({:profile_list, rest}), do: run_profile_list(rest)
  defp dispatch_command({:template_list, rest}), do: run_template_list(rest)
  defp dispatch_command({:packet_new, name, rest}), do: run_packet_new(name, rest)
  defp dispatch_command({:packet_doctor, rest}), do: run_packet_doctor(rest)
  defp dispatch_command({:packet_preflight, rest}), do: run_packet_preflight(rest)
  defp dispatch_command({:packet_explain, rest}), do: run_packet_explain(rest)
  defp dispatch_command({:packet_lint, rest}), do: run_packet_lint(rest)
  defp dispatch_command({:repo_add, name, path, rest}), do: run_repo_add(name, path, rest)
  defp dispatch_command({:prompt_new, id, rest}), do: run_prompt_new(id, rest)
  defp dispatch_command({:checklist_sync, rest}), do: run_checklist_sync(rest)
  defp dispatch_command({:list, rest}), do: run_list(rest)
  defp dispatch_command({:plan, rest}), do: run_plan(rest)
  defp dispatch_command({:run, rest}), do: run_run(rest)
  defp dispatch_command({:verify, rest}), do: run_verify(rest)
  defp dispatch_command({:start, rest}), do: run_start(rest)
  defp dispatch_command({:stop, rest}), do: run_stop(rest)
  defp dispatch_command({:repair, rest}), do: run_repair(rest)
  defp dispatch_command({:status, rest}), do: run_status(rest)
  defp dispatch_command({:watch, rest}), do: run_watch(rest)
  defp dispatch_command({:control, rest}), do: run_control(rest)
  defp dispatch_command(:help), do: show_help()
  defp dispatch_command(:unknown), do: handle_error(:unknown_command)

  defp run_version(rest) do
    {opts, _remaining, invalid} = OptionParser.parse(rest, strict: [json: :boolean])
    if invalid != [], do: handle_error({:invalid_options, invalid})

    if opts[:json],
      do: IO.puts(Jason.encode!(%{version: PromptRunner.version()})),
      else: IO.puts(PromptRunner.version())

    :ok
  end

  defp run_capabilities(rest) do
    {opts, _remaining, invalid} = OptionParser.parse(rest, strict: [json: :boolean])
    if invalid != [], do: handle_error({:invalid_options, invalid})

    if opts[:json],
      do: IO.puts(Jason.encode!(Capabilities.document())),
      else: Enum.each(Capabilities.list(), &IO.puts/1)

    :ok
  end

  defp run_workspace_plan(rest) do
    with {:ok, manifest_path} <- one_argument(rest, :workspace_manifest),
         {:ok, manifest} <- WorkspaceManifest.load(manifest_path) do
      plan = WorkspacePlan.build(manifest)

      IO.puts(
        Jason.encode!(
          %{
            schema: "prompt_runner.workspace.plan/v1",
            workspace: manifest.id,
            workspace_root: manifest.workspace_root,
            runtime_root: manifest.runtime_root,
            repositories: plan.repositories
          },
          pretty: true
        )
      )

      :ok
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_workspace_prepare(rest) do
    with {:ok, manifest_path} <- one_argument(rest, :workspace_manifest),
         {:ok, result} <- Workspace.prepare(manifest_path) do
      IO.puts(Jason.encode!(result, pretty: true))
      :ok
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_workspace_doctor(rest) do
    with {:ok, manifest_path} <- one_argument(rest, :workspace_manifest),
         {:ok, report} <- Workspace.doctor(manifest_path) do
      IO.puts(Jason.encode!(report, pretty: true))
      if report.ready?, do: :ok, else: handle_error(:workspace_not_ready)
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_workspace_import_state(rest) do
    {opts, arguments, invalid} = OptionParser.parse(rest, strict: [source: :string])

    if invalid != [] do
      handle_error({:invalid_options, invalid})
    else
      import_workspace_state(arguments, opts)
    end
  end

  defp import_workspace_state([manifest_path, packet_path], opts) do
    import_opts = maybe_put([], :source, opts[:source])

    case Workspace.import_state(manifest_path, packet_path, import_opts) do
      {:ok, result} ->
        IO.puts(Jason.encode!(result, pretty: true))
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp import_workspace_state(arguments, _opts) do
    handle_error({:expected_workspace_manifest_and_packet, arguments})
  end

  defp run_start(rest) do
    with {:ok, opts, remaining} <- parse_run_options(rest),
         {:ok, manifest_path} <- required_option(opts, :workspace),
         {:ok, packet_path} <- required_option(opts, :packet),
         true <- remaining == [] || {:error, {:unexpected_arguments, remaining}},
         {:ok, report} <- Workspace.doctor(manifest_path),
         true <- report.ready? || {:error, {:workspace_not_ready, report}},
         {:ok, %{workspace: workspace_plan, packet_root: workspace_packet_root}} <-
           Workspace.plan(manifest_path, packet_path, cli_opts(opts)),
         {:ok, executable} <- installed_executable(),
         unit = Workspace.service_unit(workspace_plan.manifest.id),
         {:ok, containment} <-
           SystemdUser.start(
             unit,
             executable,
             detached_run_argv(manifest_path, packet_path, opts),
             cwd: workspace_packet_root,
             inherit_env: inherited_service_env()
           ) do
      IO.puts(
        Jason.encode!(
          %{
            schema: "prompt_runner.service/v1",
            workspace: workspace_plan.manifest.id,
            unit: unit,
            control_group: containment.control_group,
            state: "started"
          },
          pretty: true
        )
      )

      :ok
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_stop(rest) do
    {opts, remaining, invalid} = OptionParser.parse(rest, strict: [workspace: :string])

    with true <- invalid == [] || {:error, {:invalid_options, invalid}},
         true <- remaining == [] || {:error, {:unexpected_arguments, remaining}},
         {:ok, manifest_path} <- required_option(opts, :workspace),
         {:ok, manifest} <- WorkspaceManifest.load(manifest_path),
         unit = Workspace.service_unit(manifest.id),
         :ok <- SystemdUser.stop(unit),
         {:ok, true} <- SystemdUser.empty?(unit) do
      IO.puts(
        Jason.encode!(
          %{
            schema: "prompt_runner.service/v1",
            workspace: manifest.id,
            unit: unit,
            state: "stopped"
          },
          pretty: true
        )
      )

      :ok
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  defp one_argument([argument], _name), do: {:ok, Path.expand(argument)}
  defp one_argument(arguments, name), do: {:error, {:expected_one_argument, name, arguments}}

  defp required_option(opts, key) do
    case opts[key] do
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _other -> {:error, {:missing_option, key}}
    end
  end

  defp installed_executable do
    case :escript.script_name() do
      name when is_list(name) and name != [] ->
        {:ok, Path.expand(List.to_string(name))}

      _other ->
        case System.find_executable("prompt_runner") do
          nil -> {:error, :installed_prompt_runner_not_found}
          executable -> {:ok, executable}
        end
    end
  end

  defp detached_run_argv(manifest_path, packet_path, opts) do
    ["run", "--workspace", Path.expand(manifest_path), "--packet", Path.expand(packet_path)] ++
      boolean_run_argv(opts) ++ value_run_argv(opts)
  end

  defp boolean_run_argv(opts) do
    ~w(all remaining new_run verify_first keep_going no_commit dry_run skip_preflight)a
    |> Enum.flat_map(fn key ->
      if opts[key], do: ["--#{String.replace(to_string(key), "_", "-")}"], else: []
    end)
  end

  defp value_run_argv(opts) do
    ~w(phase from through provider model log_mode log_meta events_mode tool_output thinking diff cli_confirmation runtime_store committer)a
    |> Enum.flat_map(fn key ->
      case opts[key] do
        nil -> []
        value -> ["--#{String.replace(to_string(key), "_", "-")}", to_string(value)]
      end
    end)
  end

  defp inherited_service_env do
    Enum.filter(@service_env_names, &(System.get_env(&1) not in [nil, ""]))
  end

  defp cli_opts(opts) do
    []
    |> Keyword.put(:interface, :cli)
    |> maybe_put(:provider, opts[:provider])
    |> maybe_put(:model, opts[:model])
    |> maybe_put(:log_mode, opts[:log_mode])
    |> maybe_put(:log_meta, opts[:log_meta])
    |> maybe_put(:events_mode, opts[:events_mode])
    |> maybe_put(:tool_output, opts[:tool_output])
    |> maybe_put(:thinking, opts[:thinking])
    |> maybe_put(:diff, opts[:diff])
    |> maybe_put(:cli_confirmation, opts[:cli_confirmation])
    |> maybe_put(:runtime_store, opts[:runtime_store])
    |> maybe_put(:committer, opts[:committer])
    |> maybe_put(:skip_preflight, opts[:skip_preflight])
  end

  defp parse_csv(nil), do: nil

  defp parse_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_repo_specs(nil), do: {:ok, nil}

  defp parse_repo_specs(values) do
    values
    |> List.wrap()
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case String.split(value, "=", parts: 2) do
        [name, path] when name != "" and path != "" ->
          {:cont, {:ok, acc ++ [{String.trim(name), String.trim(path)}]}}

        _ ->
          {:halt, {:error, {:invalid_repo_option, value}}}
      end
    end)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)

  defp truthy?(true), do: true
  defp truthy?(_value), do: false

  defp recovery_attrs(opts) do
    RecoveryConfig.default()
    |> put_path(["resume_attempts"], opts[:resume_attempts])
    |> put_path(["retry", "max_attempts"], opts[:retry_attempts])
    |> put_path(["retry", "base_delay_ms"], opts[:retry_base_delay_ms])
    |> put_path(["retry", "max_delay_ms"], opts[:retry_max_delay_ms])
    |> put_path(["retry", "jitter"], opts[:retry_jitter])
    |> put_path(["repair", "enabled"], opts[:auto_repair])
    |> put_path(["repair", "max_attempts"], opts[:repair_attempts])
    |> then(&RecoveryConfig.normalize(%{"recovery" => &1}))
  end

  defp put_path(map, _path, nil), do: map
  defp put_path(map, [key], value), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) do
    nested =
      map
      |> Map.get(key, %{})
      |> put_path(rest, value)

    Map.put(map, key, nested)
  end

  defp normalize_prompt_ids(ids) do
    Enum.map(ids, fn id ->
      id
      |> String.trim()
      |> String.pad_leading(2, "0")
    end)
  end

  defp normalize_optional_id(nil), do: nil
  defp normalize_optional_id(id), do: id |> String.trim() |> String.pad_leading(2, "0")

  defp print_plan_summary(plan, targets) do
    IO.puts("")
    IO.puts(UI.bold("PromptRunner Plan"))
    IO.puts("Packet: #{plan.source_root || inspect(plan.source)}")
    IO.puts("Prompts: #{length(plan.prompts)}")
    IO.puts("Selected: #{length(targets)} (#{Enum.join(targets, ", ")})")
    IO.puts("Provider: #{plan.config.llm_sdk}")
    IO.puts("Model: #{plan.config.model}")

    selected = MapSet.new(targets)

    plan.prompts
    |> Enum.filter(&MapSet.member?(selected, &1.num))
    |> Enum.each(fn prompt ->
      IO.puts("  #{prompt.num} - #{prompt.name}")
    end)

    IO.puts("")
  end

  @spec handle_error(term()) :: no_return()
  defp handle_error(:missing_prompt_id) do
    IO.puts(UI.red("ERROR: prompt id is required"))
    System.halt(1)
  end

  defp handle_error(:no_run) do
    IO.puts(UI.red("ERROR: this packet has no recorded run"))
    IO.puts("Start one with: prompt_runner run PACKET")
    System.halt(1)
  end

  defp handle_error(:empty_steer) do
    IO.puts(UI.red("ERROR: a steer needs something to say"))
    IO.puts(~s(  prompt_runner control steer PACKET "check dependency_sources.exs first"))
    System.halt(1)
  end

  defp handle_error(:reason_required) do
    IO.puts(UI.red("ERROR: --reason is mandatory"))
    IO.puts("An amendment with no stated reason is refused, not defaulted.")
    System.halt(1)
  end

  defp handle_error(:confirmation_required) do
    IO.puts(UI.red("ERROR: relax needs --confirm"))

    IO.puts(
      "Removing a requirement is the risky direction. Adding one is `control amend`;\n" <>
        "weakening one says so out loud."
    )

    System.halt(1)
  end

  defp handle_error(:no_amendment) do
    IO.puts(UI.red("ERROR: name what to add"))
    IO.puts("  --add-file PATH | --add-command CMD | --add-path PATH")
    System.halt(1)
  end

  defp handle_error(:no_relaxation) do
    IO.puts(UI.red("ERROR: name the clause to drop"))
    IO.puts("  --drop contains")
    System.halt(1)
  end

  defp handle_error(:no_view_settings) do
    IO.puts(UI.red("ERROR: name at least one setting"))
    IO.puts("  prompt_runner control view PACKET --tool-output full")
    System.halt(1)
  end

  defp handle_error(:unknown_command) do
    IO.puts(UI.red("ERROR: unknown command"))
    show_help()
    System.halt(1)
  end

  defp handle_error(reason) do
    IO.puts(UI.red("ERROR: #{inspect(reason)}"))
    System.halt(1)
  end

  defp show_help do
    IO.puts("""

    Prompt Runner #{PromptRunner.version()}

    Setup:
      prompt_runner init
      prompt_runner profile new NAME [--provider codex --model gpt-5.6-luna --reasoning xhigh] [--prompt-template from-adr]
      prompt_runner profile list
      prompt_runner template list [PACKET_DIR]

    Packet authoring:
      prompt_runner packet new NAME [--root DIR] [--profile NAME] [--repo NAME=PATH] [--default-repo NAME]
      prompt_runner packet new NAME [--prompt-template TEMPLATE] [--provider PROVIDER] [--model MODEL]
      prompt_runner packet doctor [PACKET_DIR]
      prompt_runner packet preflight [PACKET_DIR]
      prompt_runner packet explain [PACKET_DIR]
      prompt_runner packet lint [PACKET_DIR] [--strict] [--json]
      prompt_runner repo add NAME PATH [--packet PACKET_DIR] [--default]
      prompt_runner prompt new ID [--packet PACKET_DIR] --phase N --name "..." [--template TEMPLATE]
      prompt_runner checklist sync [PACKET_DIR]

    Operator workspaces:
      prompt_runner workspace plan MANIFEST
      prompt_runner workspace prepare MANIFEST
      prompt_runner workspace doctor MANIFEST
      prompt_runner workspace import-state MANIFEST PACKET_DIR [--source PROGRESS_FILE]
      prompt_runner start --workspace MANIFEST --packet PACKET_DIR --remaining [--new-run] [--from ID] [--through ID]
      prompt_runner status --workspace MANIFEST [--json]
      prompt_runner watch --workspace MANIFEST [--for 240m] [--every 10m]
        [--require-running] [--require-progress] [--progress-timeout 60m] [--json]
      prompt_runner stop --workspace MANIFEST

    Execution:
      prompt_runner list [PACKET_DIR]
      prompt_runner plan [PACKET_DIR] [--provider PROVIDER] [--model MODEL]
      prompt_runner run [PACKET_DIR] [PROMPT_ID...] [--skip-preflight] [--dry-run]
      prompt_runner run [PACKET_DIR] --remaining [--new-run] [--verify-first | --no-verify-first] [--keep-going]
      prompt_runner verify [PACKET_DIR] [PROMPT_ID...] [--workspace MANIFEST] [--json]
      prompt_runner repair [--packet PACKET_DIR] PROMPT_ID
      prompt_runner status [PACKET_DIR]
      prompt_runner watch [PACKET_DIR] [--interval SECONDS] [--once] [--json]

    Control (a live run, from another terminal):
      prompt_runner control status [PACKET_DIR | --workspace MANIFEST] [--json]
      prompt_runner control view [PACKET_DIR | --workspace MANIFEST] [--log-mode MODE] [--tool-output MODE] [--diff MODE]
      prompt_runner control log [PACKET_DIR | --workspace MANIFEST] [--follow] [--json]
      prompt_runner control events [PACKET_DIR | --workspace MANIFEST] [--from current] [--json]
      prompt_runner control steer [PACKET_DIR | --workspace MANIFEST] TEXT... [--author NAME]
      prompt_runner control contract [PACKET_DIR] PROMPT_ID [--json]
      prompt_runner control contract --workspace MANIFEST --packet PACKET_DIR PROMPT_ID [--json]
      prompt_runner control amend [PACKET_DIR] PROMPT_ID --add-file PATH --reason "..." [--persist]
      prompt_runner control amend --workspace MANIFEST --packet PACKET_DIR PROMPT_ID --add-file PATH --reason "..."
      prompt_runner control relax [PACKET_DIR] PROMPT_ID --drop CLAUSE --reason "..." --confirm
      prompt_runner control relax --workspace MANIFEST --packet PACKET_DIR PROMPT_ID --drop CLAUSE --reason "..." --confirm

    `plan` and `run` accept the same override flags, so `plan` shows exactly
    what `run` would resolve.

    `--remaining` runs every prompt whose recorded status is not `completed`,
    in order, including ones earlier than the furthest one that finished. It
    pre-verifies each prompt first and skips any whose contract already passes;
    `--no-verify-first` turns that off.

    `--keep-going` records a prompt-local failure and continues with the rest of
    the selected prompts. The command still exits non-zero after the selection
    and reports every failed prompt. Without it, runs remain fail-fast.

    `--new-run` explicitly supersedes a failed or interrupted run generation,
    preserving its journal and prompt progress while accepting the current
    packet fingerprint. Without that flag, a changed packet fails closed.

    """)
  end
end
