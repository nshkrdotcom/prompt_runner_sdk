defmodule PromptRunner.CLI do
  @moduledoc """
  Command-line entrypoint for the Prompt Runner packet workflow.
  """

  alias PromptRunner
  alias PromptRunner.CLI.Control, as: CLIControl
  alias PromptRunner.Packet
  alias PromptRunner.PacketLint
  alias PromptRunner.Packets
  alias PromptRunner.Profile
  alias PromptRunner.RecoveryConfig
  alias PromptRunner.Runner
  alias PromptRunner.Template
  alias PromptRunner.UI
  alias PromptRunner.Watch

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
    verify_first: :boolean,
    phase: :integer,
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
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: @run_switches)
    packet_dir = packet_dir(remaining)

    case PromptRunner.plan(packet_dir, cli_opts(opts)) do
      {:ok, plan} ->
        print_plan_summary(plan)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_run(rest) do
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: @run_switches)

    {packet_dir, prompt_ids} = packet_and_prompt_ids(remaining)

    case PromptRunner.plan(packet_dir, cli_opts(opts)) do
      {:ok, plan} ->
        cli_run_opts =
          opts
          |> cli_opts()
          |> Keyword.put(:run, true)
          |> maybe_put(:all, opts[:all] || (prompt_ids == [] and not truthy?(opts[:remaining])))
          |> maybe_put(:remaining, opts[:remaining])
          |> maybe_put(:verify_first, opts[:verify_first])
          |> maybe_put(:phase, opts[:phase])
          |> maybe_put(:no_commit, opts[:no_commit])
          |> maybe_put(:dry_run, opts[:dry_run])

        case Runner.execute_plan(plan, cli_run_opts, prompt_ids) do
          :ok -> :ok
          {:error, reason} -> handle_error(reason)
        end

      {:error, reason} ->
        handle_error(reason)
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
    packet_dir = packet_dir(rest)

    {:ok, status} = PromptRunner.status(packet_dir)
    IO.puts(Jason.encode!(status, pretty: true))
    :ok
  end

  defp run_watch(rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [interval: :integer, once: :boolean, json: :boolean]
      )

    packet_dir = packet_dir(remaining)

    case Watch.run(packet_dir, opts) do
      :ok -> :ok
      {:error, reason} -> handle_error(reason)
    end
  end

  defp run_control(["status" | rest]) do
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: [json: :boolean])
    control_result(CLIControl.status(packet_dir(remaining), opts))
  end

  defp run_control(["view" | rest]) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [log_mode: :string, tool_output: :string, diff: :string]
      )

    control_result(CLIControl.view(packet_dir(remaining), opts))
  end

  defp run_control(["steer" | rest]) do
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: [author: :string])

    case remaining do
      [] -> handle_error(:empty_steer)
      [packet | words] -> steer_target(packet, words, opts)
    end
  end

  defp run_control(["pause" | rest]) do
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: [author: :string])
    control_result(CLIControl.pause(packet_dir(remaining), opts))
  end

  defp run_control(["amend" | rest]) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          add_file: :string,
          add_command: :string,
          add_path: :string,
          reason: :string,
          persist: :boolean
        ]
      )

    with_prompt_target(remaining, &control_result(CLIControl.amend(&1, &2, opts)))
  end

  defp run_control(["relax" | rest]) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [drop: :string, reason: :string, confirm: :boolean, persist: :boolean]
      )

    with_prompt_target(remaining, &control_result(CLIControl.relax(&1, &2, opts)))
  end

  defp run_control(["contract" | rest]) do
    {opts, remaining, _invalid} = OptionParser.parse(rest, switches: [json: :boolean])
    with_prompt_target(remaining, &control_result(CLIControl.contract(&1, &2, opts)))
  end

  defp run_control(["log" | rest]) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest, switches: [follow: :boolean, json: :boolean])

    control_result(CLIControl.log(packet_dir(remaining), opts))
  end

  defp run_control(["events" | rest]) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest, switches: [json: :boolean, from: :string])

    from = if opts[:from] == "current", do: :current, else: :start
    control_result(CLIControl.watch(packet_dir(remaining), Keyword.put(opts, :from, from)))
  end

  defp run_control(_rest), do: handle_error(:unknown_command)

  # `control steer PACKET some words` and `control steer some words` both have
  # to work, and only the filesystem can tell them apart.
  defp steer_target(first, words, opts) do
    if File.dir?(first) do
      control_result(CLIControl.steer(first, words, opts))
    else
      control_result(CLIControl.steer(File.cwd!(), [first | words], opts))
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

  defp packet_and_prompt_ids([]), do: {File.cwd!(), []}

  defp packet_and_prompt_ids([first | rest]) do
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
  defp dispatch_command({:repair, rest}), do: run_repair(rest)
  defp dispatch_command({:status, rest}), do: run_status(rest)
  defp dispatch_command({:watch, rest}), do: run_watch(rest)
  defp dispatch_command({:control, rest}), do: run_control(rest)
  defp dispatch_command(:help), do: show_help()
  defp dispatch_command(:unknown), do: handle_error(:unknown_command)

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

  defp print_plan_summary(plan) do
    IO.puts("")
    IO.puts(UI.bold("PromptRunner Plan"))
    IO.puts("Packet: #{plan.source_root || inspect(plan.source)}")
    IO.puts("Prompts: #{length(plan.prompts)}")
    IO.puts("Provider: #{plan.config.llm_sdk}")
    IO.puts("Model: #{plan.config.model}")

    Enum.each(plan.prompts, fn prompt ->
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

    Execution:
      prompt_runner list [PACKET_DIR]
      prompt_runner plan [PACKET_DIR] [--provider PROVIDER] [--model MODEL]
      prompt_runner run [PACKET_DIR] [PROMPT_ID...] [--skip-preflight] [--dry-run]
      prompt_runner run [PACKET_DIR] --remaining [--verify-first | --no-verify-first]
      prompt_runner repair [--packet PACKET_DIR] PROMPT_ID
      prompt_runner status [PACKET_DIR]
      prompt_runner watch [PACKET_DIR] [--interval SECONDS] [--once] [--json]

    Control (a live run, from another terminal):
      prompt_runner control status [PACKET_DIR] [--json]
      prompt_runner control view [PACKET_DIR] [--log-mode MODE] [--tool-output MODE] [--diff MODE]
      prompt_runner control log [PACKET_DIR] [--follow] [--json]
      prompt_runner control events [PACKET_DIR] [--from current] [--json]
      prompt_runner control steer [PACKET_DIR] TEXT... [--author NAME]
      prompt_runner control pause [PACKET_DIR] [--author NAME]
      prompt_runner control contract [PACKET_DIR] PROMPT_ID [--json]
      prompt_runner control amend [PACKET_DIR] PROMPT_ID --add-file PATH --reason "..." [--persist]
      prompt_runner control relax [PACKET_DIR] PROMPT_ID --drop CLAUSE --reason "..." --confirm

    `plan` and `run` accept the same override flags, so `plan` shows exactly
    what `run` would resolve.

    `--remaining` runs every prompt whose recorded status is not `completed`,
    in order, including ones earlier than the furthest one that finished. It
    pre-verifies each prompt first and skips any whose contract already passes;
    `--no-verify-first` turns that off.

    """)
  end
end
