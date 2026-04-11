defmodule PromptRunner.CLI do
  @moduledoc """
  Command-line entrypoint for the Prompt Runner packet workflow.
  """

  alias PromptRunner
  alias PromptRunner.Packet
  alias PromptRunner.Packets
  alias PromptRunner.Profile
  alias PromptRunner.RecoveryConfig
  alias PromptRunner.Runner
  alias PromptRunner.UI

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

  defp run_packet_new(name, rest) do
    {opts, _remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          root: :string,
          profile: :string,
          provider: :string,
          model: :string,
          reasoning: :string,
          permission: :string,
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

    packet_opts =
      []
      |> maybe_put(:root, opts[:root])
      |> maybe_put(:profile, opts[:profile])
      |> maybe_put(:provider, opts[:provider])
      |> maybe_put(:model, opts[:model])
      |> maybe_put(:reasoning_effort, opts[:reasoning])
      |> maybe_put(:permission_mode, opts[:permission])
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
          commit: :string
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
      {:ok, paths} ->
        IO.puts(UI.green("Synchronized checklists"))
        Enum.each(paths, &IO.puts("  #{&1}"))
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
    packet_dir = packet_dir(rest)

    case PromptRunner.plan(packet_dir, interface: :cli) do
      {:ok, plan} ->
        print_plan_summary(plan)
        :ok

      {:error, reason} ->
        handle_error(reason)
    end
  end

  defp run_run(rest) do
    {opts, remaining, _invalid} =
      OptionParser.parse(rest,
        switches: [
          all: :boolean,
          phase: :integer,
          no_commit: :boolean,
          provider: :string,
          model: :string,
          log_mode: :string,
          log_meta: :string,
          events_mode: :string,
          tool_output: :string,
          cli_confirmation: :string,
          runtime_store: :string,
          committer: :string
        ]
      )

    {packet_dir, prompt_ids} = packet_and_prompt_ids(remaining)

    case PromptRunner.plan(packet_dir, cli_opts(opts)) do
      {:ok, plan} ->
        cli_run_opts =
          opts
          |> cli_opts()
          |> Keyword.put(:run, true)
          |> maybe_put(:all, opts[:all] || prompt_ids == [])
          |> maybe_put(:phase, opts[:phase])
          |> maybe_put(:no_commit, opts[:no_commit])

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
  defp parse_command(["packet", "new", name | rest]), do: {:packet_new, name, rest}
  defp parse_command(["packet", "doctor" | rest]), do: {:packet_doctor, rest}
  defp parse_command(["packet", "explain" | rest]), do: {:packet_explain, rest}
  defp parse_command(["repo", "add", name, path | rest]), do: {:repo_add, name, path, rest}
  defp parse_command(["prompt", "new", id | rest]), do: {:prompt_new, id, rest}
  defp parse_command(["checklist", "sync" | rest]), do: {:checklist_sync, rest}
  defp parse_command(["list" | rest]), do: {:list, rest}
  defp parse_command(["plan" | rest]), do: {:plan, rest}
  defp parse_command(["run" | rest]), do: {:run, rest}
  defp parse_command(["repair" | rest]), do: {:repair, rest}
  defp parse_command(["status" | rest]), do: {:status, rest}
  defp parse_command(["help" | _rest]), do: :help
  defp parse_command(["--help" | _rest]), do: :help
  defp parse_command(["-h" | _rest]), do: :help
  defp parse_command([]), do: :help
  defp parse_command(_args), do: :unknown

  defp dispatch_command({:init, rest}), do: run_init(rest)
  defp dispatch_command({:profile_new, name, rest}), do: run_profile_new(name, rest)
  defp dispatch_command({:profile_list, rest}), do: run_profile_list(rest)
  defp dispatch_command({:packet_new, name, rest}), do: run_packet_new(name, rest)
  defp dispatch_command({:packet_doctor, rest}), do: run_packet_doctor(rest)
  defp dispatch_command({:packet_explain, rest}), do: run_packet_explain(rest)
  defp dispatch_command({:repo_add, name, path, rest}), do: run_repo_add(name, path, rest)
  defp dispatch_command({:prompt_new, id, rest}), do: run_prompt_new(id, rest)
  defp dispatch_command({:checklist_sync, rest}), do: run_checklist_sync(rest)
  defp dispatch_command({:list, rest}), do: run_list(rest)
  defp dispatch_command({:plan, rest}), do: run_plan(rest)
  defp dispatch_command({:run, rest}), do: run_run(rest)
  defp dispatch_command({:repair, rest}), do: run_repair(rest)
  defp dispatch_command({:status, rest}), do: run_status(rest)
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
    |> maybe_put(:cli_confirmation, opts[:cli_confirmation])
    |> maybe_put(:runtime_store, opts[:runtime_store])
    |> maybe_put(:committer, opts[:committer])
  end

  defp parse_csv(nil), do: nil

  defp parse_csv(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value) when is_map(map), do: Map.put(map, key, value)
  defp maybe_put(opts, key, value) when is_list(opts), do: Keyword.put(opts, key, value)

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

    Prompt Runner 0.7.0

    Setup:
      prompt_runner init
      prompt_runner profile new NAME [--provider codex --model gpt-5.4 --reasoning xhigh]
      prompt_runner profile list

    Packet authoring:
      prompt_runner packet new NAME [--root DIR] [--profile NAME] [--provider PROVIDER] [--model MODEL]
      prompt_runner packet doctor [PACKET_DIR]
      prompt_runner packet explain [PACKET_DIR]
      prompt_runner repo add NAME PATH [--packet PACKET_DIR] [--default]
      prompt_runner prompt new ID [--packet PACKET_DIR] --phase N --name "..."
      prompt_runner checklist sync [PACKET_DIR]

    Execution:
      prompt_runner list [PACKET_DIR]
      prompt_runner plan [PACKET_DIR]
      prompt_runner run [PACKET_DIR] [PROMPT_ID...]
      prompt_runner repair [--packet PACKET_DIR] PROMPT_ID
      prompt_runner status [PACKET_DIR]

    """)
  end
end
