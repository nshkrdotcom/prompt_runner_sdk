defmodule PromptRunner.Verifier do
  @moduledoc """
  Deterministic prompt verification.
  """

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias PromptRunner.Config
  alias PromptRunner.Control.Amendment
  alias PromptRunner.Paths
  alias PromptRunner.Plan
  alias PromptRunner.Verifier.Doc
  alias PromptRunner.Verifier.Glob
  alias PromptRunner.Verifier.JSON
  alias PromptRunner.Verifier.ReposClean
  alias PromptRunner.Verifier.SourceAbsent
  alias PromptRunner.Verifier.Yaml

  @type fault :: :verifier_fault | :verifier_timeout

  @type report :: %{
          pass?: boolean(),
          items: [map()],
          failures: [map()],
          faults: [map()],
          prompt_id: String.t() | nil,
          amendments: [map()]
        }

  # Exit codes that say the check never ran, as opposed to ran and disagreed.
  # `bash -c` reports 127 for a command it could not find and 126 for one it
  # found and could not execute; `timeout` reports 124 when it killed its child.
  # None of these is evidence about the work in either direction, and reading
  # them as a verification failure discards finished attempts — which is exactly
  # what happened on 2026-08-10 when a contract kept referencing scripts after
  # they moved.
  @fault_exit_codes %{126 => :verifier_fault, 127 => :verifier_fault, 124 => :verifier_timeout}

  @fault_reasons %{
    126 => "command found but not executable",
    127 => "command not found",
    124 => "killed by timeout"
  }

  @contract_keys ~w(
    files_exist
    files_absent
    contains
    matches
    doc
    yaml
    json
    glob
    source_absent
    commands
    changed_paths_only
    repos_clean
  )

  @doc """
  Returns the contract clauses the verifier evaluates.

  Anything else under `verify:` is parsed, stored, and never evaluated, which
  is what `mix prompt_runner packet lint` reads this list to detect.
  """
  @spec contract_keys() :: [String.t()]
  def contract_keys, do: @contract_keys

  @spec verify(Plan.t(), keyword()) :: {:ok, [report()]}
  def verify(%Plan{} = plan, opts \\ []) do
    prompt_ids = Keyword.get(opts, :prompts)

    prompts =
      case prompt_ids do
        nil -> plan.prompts
        ids -> Enum.filter(plan.prompts, &(&1.num in List.wrap(ids)))
      end

    {:ok, Enum.map(prompts, &verify_prompt(plan, &1))}
  end

  @spec verify_prompt(Plan.t(), map(), keyword()) :: report()
  def verify_prompt(%Plan{} = plan, prompt, opts \\ []) do
    repo_index = repo_index(plan)
    default_scope = default_scope(plan, prompt, repo_index)

    contract =
      plan
      |> enforced_contract(prompt, opts)
      |> normalize_contract(prompt.validation_commands || [])
      |> maybe_without_commands(opts)

    items =
      []
      |> Kernel.++(verify_files_exist(contract, repo_index, default_scope))
      |> Kernel.++(verify_files_absent(contract, repo_index, default_scope))
      |> Kernel.++(verify_contains(contract, repo_index, default_scope))
      |> Kernel.++(verify_matches(contract, repo_index, default_scope))
      |> Kernel.++(verify_doc(contract, repo_index, default_scope))
      |> Kernel.++(verify_yaml(contract, repo_index, default_scope))
      |> Kernel.++(verify_json(contract, repo_index, default_scope))
      |> Kernel.++(verify_glob(contract, repo_index, default_scope))
      |> Kernel.++(verify_source_absent(contract, repo_index, default_scope))
      |> Kernel.++(verify_commands(contract, repo_index, default_scope))
      |> Kernel.++(verify_changed_paths_only(contract, repo_index, default_scope))
      |> Kernel.++(verify_repos_clean(contract, repo_index, default_scope))

    failures = Enum.reject(items, & &1.pass?)

    %{
      pass?: failures == [],
      items: items,
      failures: failures,
      faults: Enum.filter(items, &fault_item?/1),
      prompt_id: prompt.num,
      amendments: amendment_records(plan, prompt, opts)
    }
  end

  defp maybe_without_commands(contract, opts) do
    if Keyword.get(opts, :executable, true), do: contract, else: Map.delete(contract, "commands")
  end

  @doc """
  The contract actually enforced for a prompt: the packet's, plus every
  amendment recorded for it.

  The packet's own contract is never mutated. It is read fresh each time and
  the amendments are applied on top, so a re-run from clean state — with no
  amendment log — enforces exactly what the packet says.
  """
  @spec enforced_contract(Plan.t(), map(), keyword()) :: map()
  def enforced_contract(%Plan{} = plan, prompt, opts \\ []) do
    packet_contract = prompt.verify || %{}

    case amendment_records(plan, prompt, opts) do
      [] -> packet_contract
      amendments -> Amendment.enforced_contract(packet_contract, amendments)
    end
  end

  defp amendment_records(%Plan{} = plan, prompt, opts) do
    case {Keyword.get(opts, :amendments, true), amendment_root(plan)} do
      {true, root} when not is_nil(root) -> Amendment.read(root, prompt.num)
      _other -> []
    end
  end

  defp amendment_root(%Plan{state_dir: state_dir}) when is_binary(state_dir),
    do: {:state_root, state_dir}

  defp amendment_root(%Plan{source_root: source_root}) when is_binary(source_root),
    do: source_root

  defp amendment_root(_plan), do: nil

  @doc """
  The items in `report` whose check could not run.

  A fault is not a verification failure. The contract said nothing about the
  work because it never got to look, so a caller must neither pass the prompt
  nor spend an attempt trying to repair it — it has to stop and say what could
  not run.
  """
  @spec faults(report() | map()) :: [map()]
  def faults(report) when is_map(report) do
    case Map.get(report, :faults, Map.get(report, "faults")) do
      faults when is_list(faults) ->
        faults

      _ ->
        report
        |> Map.get(:items, Map.get(report, "items", []))
        |> List.wrap()
        |> Enum.filter(&fault_item?/1)
    end
  end

  @doc """
  Whether `report` contains any item whose check could not run.
  """
  @spec fault?(report() | map()) :: boolean()
  def fault?(report) when is_map(report), do: faults(report) != []

  @doc """
  A one-line description of a faulted item, naming the command and its cwd.
  """
  @spec fault_line(map()) :: String.t()
  def fault_line(item) when is_map(item) do
    exit_code = item_field(item, :exit_code)
    reason = Map.get(@fault_reasons, exit_code, "check could not run")

    "#{item_field(item, :fault) || "verifier_fault"} exit=#{exit_code} (#{reason}) " <>
      "cwd=#{item_field(item, :cwd) || "?"} command=#{inspect(item_field(item, :command))}"
  end

  defp fault_item?(item) when is_map(item), do: item_field(item, :fault) != nil
  defp fault_item?(_item), do: false

  defp item_field(item, key) when is_map(item) do
    Map.get(item, key) || Map.get(item, Atom.to_string(key))
  end

  @spec contract_items(map()) :: [map()]
  def contract_items(contract) when is_map(contract) do
    normalize_contract(contract, [])
    |> Enum.flat_map(fn
      {"files_exist", entries} ->
        Enum.map(entries, &%{label: "file exists: #{format_entry_path(&1)}"})

      {"files_absent", entries} ->
        Enum.map(entries, &%{label: "file absent: #{format_entry_path(&1)}"})

      {"contains", entries} ->
        Enum.map(entries, &%{label: "contains: #{format_entry_path(&1)}"})

      {"matches", entries} ->
        Enum.map(entries, &%{label: "matches: #{format_entry_path(&1)}"})

      {"doc", entries} ->
        Enum.map(entries, &%{label: doc_label(&1)})

      {"yaml", entries} ->
        Enum.map(entries, &%{label: "YAML parses: #{format_entry_path(&1)}"})

      {"json", entries} ->
        Enum.map(entries, &%{label: "JSON contract: #{format_entry_path(&1)}"})

      {"glob", entries} ->
        Enum.map(entries, &%{label: "glob contract: #{format_entry_path(&1)}"})

      {"source_absent", entries} ->
        Enum.map(entries, &%{label: "forbidden source absent: #{format_entry_path(&1)}"})

      {"repos_clean", entries} ->
        Enum.map(entries, &%{label: ReposClean.label(&1)})

      {"commands", entries} ->
        Enum.map(entries, &%{label: "command: #{format_command(&1)}"})

      {"changed_paths_only", entries} ->
        Enum.map(entries, &%{label: "changed path allowed: #{format_entry_path(&1)}"})

      {_key, _entries} ->
        []
    end)
  end

  defp verify_files_exist(contract, repo_index, default_scope) do
    contract
    |> Map.get("files_exist", [])
    |> Enum.map(fn entry ->
      %{repo: repo, path: rel_path, resolved_path: path} =
        resolve_entry(entry, repo_index, default_scope)

      %{
        kind: "file_exists",
        repo: repo,
        path: rel_path,
        resolved_path: path,
        pass?: File.exists?(path),
        details: if(File.exists?(path), do: "ok", else: "missing")
      }
    end)
  end

  defp verify_files_absent(contract, repo_index, default_scope) do
    contract
    |> Map.get("files_absent", [])
    |> Enum.map(fn entry ->
      %{repo: repo, path: rel_path, resolved_path: path} =
        resolve_entry(entry, repo_index, default_scope)

      %{
        kind: "file_absent",
        repo: repo,
        path: rel_path,
        resolved_path: path,
        pass?: not File.exists?(path),
        details: if(File.exists?(path), do: "present", else: "ok")
      }
    end)
  end

  defp verify_contains(contract, repo_index, default_scope) do
    contract
    |> Map.get("contains", [])
    |> Enum.map(fn entry ->
      %{repo: repo, path: rel_path, resolved_path: path, text: text} =
        resolve_content_entry(entry, repo_index, default_scope)

      content =
        case File.read(path) do
          {:ok, value} -> value
          {:error, _reason} -> nil
        end

      %{
        kind: "contains",
        repo: repo,
        path: rel_path,
        resolved_path: path,
        pass?: is_binary(content) and String.contains?(content, text || ""),
        details: if(is_binary(content), do: "checked", else: "missing_file")
      }
    end)
  end

  defp verify_matches(contract, repo_index, default_scope) do
    contract
    |> Map.get("matches", [])
    |> Enum.map(fn entry ->
      %{repo: repo, path: rel_path, resolved_path: path, pattern: pattern} =
        resolve_match_entry(entry, repo_index, default_scope)

      content =
        case File.read(path) do
          {:ok, value} -> value
          {:error, _reason} -> nil
        end

      regex =
        case Regex.compile(pattern || "") do
          {:ok, compiled} -> compiled
          {:error, _reason} -> nil
        end

      %{
        kind: "matches",
        repo: repo,
        path: rel_path,
        resolved_path: path,
        pass?: is_binary(content) and is_struct(regex, Regex) and Regex.match?(regex, content),
        details: if(is_binary(content), do: "checked", else: "missing_file")
      }
    end)
  end

  defp verify_doc(contract, repo_index, default_scope) do
    contract
    |> Map.get("doc", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_entry(repo_index, default_scope)
      |> Doc.report(entry)
    end)
  end

  defp verify_yaml(contract, repo_index, default_scope) do
    contract
    |> Map.get("yaml", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_entry(repo_index, default_scope)
      |> Yaml.report(entry)
    end)
  end

  defp verify_json(contract, repo_index, default_scope) do
    contract
    |> Map.get("json", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_entry(repo_index, default_scope)
      |> JSON.report(entry)
    end)
  end

  defp verify_glob(contract, repo_index, default_scope) do
    contract
    |> Map.get("glob", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_entry(repo_index, default_scope)
      |> Glob.report(entry)
    end)
  end

  defp verify_source_absent(contract, repo_index, default_scope) do
    contract
    |> Map.get("source_absent", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_entry(repo_index, default_scope)
      |> SourceAbsent.report(entry)
    end)
  end

  defp verify_repos_clean(contract, repo_index, default_scope) do
    contract
    |> Map.get("repos_clean", [])
    |> Enum.map(fn entry ->
      repo = ReposClean.entry_repo(entry) || repo_for_scope(repo_index, default_scope)
      ReposClean.report(repo, repo_root(repo_index, repo), entry)
    end)
  end

  defp verify_commands(contract, repo_index, default_scope) do
    contract
    |> Map.get("commands", [])
    |> Enum.map(fn entry ->
      entry
      |> resolve_command_entry(repo_index, default_scope)
      |> verify_command()
    end)
  end

  defp verify_command(%{mode: :structured} = command) do
    case resolve_executable(command.program, command.cwd) do
      {:ok, executable} ->
        verify_resolved_command(command, executable)

      {:error, reason} ->
        command_item(command, %{
          exit_code: nil,
          fault: missing_executable_fault(command.program),
          pass?: false,
          details: reason
        })
    end
  end

  defp verify_command(%{mode: :legacy_shell} = command) do
    {output, code} =
      System.cmd("bash", ["-c", command.command], cd: command.cwd, stderr_to_stdout: true)

    fault = Map.get(@fault_exit_codes, code)

    command_item(command, %{
      exit_code: code,
      fault: fault,
      pass?: code == 0,
      details: command_details(fault, code, output)
    })
  end

  defp verify_resolved_command(command, executable) do
    invocation = Command.new(executable, command.argv, cwd: command.cwd, env: command.env)

    case stage_regeneration(command.regenerates) do
      {:ok, regeneration} ->
        command
        |> run_structured_command(invocation)
        |> finalize_regeneration(regeneration)

      {:error, reason} ->
        command_item(command, %{
          exit_code: nil,
          fault: :verifier_fault,
          pass?: false,
          details: "could not stage regenerated outputs: #{inspect(reason)}"
        })
    end
  end

  defp run_structured_command(command, invocation) do
    case Command.run(invocation, timeout: command.timeout_ms, stderr: :stdout) do
      {:ok, %RunResult{} = result} ->
        code = result.exit.code
        {output_pass?, output_details} = output_assertion(command, result.output)
        fault = if code in command.fault_exit_codes, do: :verifier_fault, else: nil

        command_item(command, %{
          exit_code: code,
          fault: fault,
          pass?: is_nil(fault) and RunResult.success?(result) and output_pass?,
          details: output_details
        })

      {:error, error} ->
        fault = structured_command_fault(error)

        command_item(command, %{
          exit_code: nil,
          fault: fault,
          pass?: false,
          details: Exception.message(error)
        })
    end
  end

  defp stage_regeneration([]), do: {:ok, []}

  defp stage_regeneration(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, staged} ->
      case stage_regenerated_path(path) do
        {:ok, record} ->
          {:cont, {:ok, [record | staged]}}

        {:error, reason} ->
          rollback_regeneration(staged)
          {:halt, {:error, {path, reason}}}
      end
    end)
  end

  defp stage_regenerated_path(path) do
    backup = path <> ".prompt-runner-verifier-backup"

    with :ok <- recover_regeneration_backup(path, backup),
         {:ok, existed?} <- move_regeneration_source(path, backup) do
      {:ok, %{path: path, backup: backup, existed?: existed?}}
    end
  end

  defp recover_regeneration_backup(path, backup) do
    cond do
      File.exists?(backup) and not File.exists?(path) -> File.rename(backup, path)
      File.exists?(backup) -> {:error, :ambiguous_existing_backup}
      true -> :ok
    end
  end

  defp move_regeneration_source(path, backup) do
    if File.exists?(path) do
      case File.rename(path, backup) do
        :ok -> {:ok, true}
        {:error, reason} -> {:error, reason}
      end
    else
      {:ok, false}
    end
  end

  defp finalize_regeneration(item, []), do: item

  defp finalize_regeneration(item, staged) do
    missing =
      staged
      |> Enum.map(& &1.path)
      |> Enum.reject(&non_empty_regular?/1)

    if item.pass? and missing == [] do
      Enum.each(staged, &File.rm(&1.backup))
      Map.put(item, :regenerated, Enum.map(staged, & &1.path))
    else
      rollback_regeneration(staged)

      if missing == [] do
        item
      else
        %{
          item
          | pass?: false,
            details:
              item.details <>
                "\nregenerated output missing or empty: " <> Enum.join(missing, ", ")
        }
      end
    end
  end

  defp rollback_regeneration(staged) do
    Enum.each(staged, fn record ->
      _ = File.rm(record.path)

      if record.existed? and File.exists?(record.backup) do
        _ = File.rename(record.backup, record.path)
      else
        _ = File.rm(record.backup)
      end
    end)
  end

  defp non_empty_regular?(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> true
      _other -> false
    end
  end

  defp resolve_executable(program, cwd) do
    cond do
      Path.type(program) == :absolute and File.regular?(program) ->
        {:ok, program}

      String.contains?(program, "/") ->
        path = Path.expand(program, cwd)
        if File.regular?(path), do: {:ok, path}, else: {:error, "executable not found: #{path}"}

      executable = System.find_executable(program) ->
        {:ok, executable}

      true ->
        {:error, "executable not found on PATH: #{program}"}
    end
  end

  # A relative executable path may be an artifact the prompt is responsible
  # for creating. Its absence after the session is failed work. A bare PATH
  # command or an absolute prerequisite is runner infrastructure and remains a
  # fault, so it cannot spend a repair attempt or be mistaken for bad output.
  defp missing_executable_fault(program) do
    if Path.type(program) == :relative and String.contains?(program, "/"),
      do: nil,
      else: :verifier_fault
  end

  defp command_item(command, attrs) do
    Map.merge(
      %{
        kind: "command",
        mode: command.mode,
        repo: command.repo,
        command: command.command,
        cwd: command.cwd,
        argv: Map.get(command, :argv),
        timeout_ms: Map.get(command, :timeout_ms)
      },
      attrs
    )
  end

  defp structured_command_fault(%{reason: {:transport, %{reason: :timeout}}}),
    do: :verifier_timeout

  defp structured_command_fault(_error), do: :verifier_fault

  defp output_assertion(command, output) do
    cond do
      is_binary(command.stdout_contains) ->
        pass? = String.contains?(output, command.stdout_contains)

        {pass?,
         if(pass?,
           do: String.trim(output),
           else: "stdout missing #{inspect(command.stdout_contains)}\n#{String.trim(output)}"
         )}

      is_binary(command.stdout_matches) ->
        case Regex.compile(command.stdout_matches, "iu") do
          {:ok, regex} ->
            pass? = Regex.match?(regex, output)

            {pass?,
             if(pass?,
               do: String.trim(output),
               else:
                 "stdout did not match #{inspect(command.stdout_matches)}\n#{String.trim(output)}"
             )}

          {:error, reason} ->
            {false, "invalid stdout_matches regex: #{inspect(reason)}"}
        end

      true ->
        {true, String.trim(output)}
    end
  end

  defp command_details(nil, _code, output), do: String.trim(output)

  defp command_details(fault, code, output) do
    "#{fault}: #{Map.fetch!(@fault_reasons, code)} (exit #{code})\n" <> String.trim(output)
  end

  defp verify_changed_paths_only(contract, repo_index, default_scope) do
    allowed_entries =
      contract
      |> Map.get("changed_paths_only", [])
      |> Enum.map(&resolve_entry(&1, repo_index, default_scope))

    allowed_by_repo =
      Enum.group_by(allowed_entries, & &1.repo, fn entry -> entry.path end)

    Enum.flat_map(allowed_by_repo, &verify_changed_paths_repo(&1, repo_index))
  end

  defp normalize_contract(contract, validation_commands) when is_map(contract) do
    contract
    |> stringify_keys()
    |> Map.update("commands", normalize_entries(validation_commands), fn commands ->
      normalize_entries(commands)
    end)
    |> Map.update("files_exist", [], &normalize_entries/1)
    |> Map.update("files_absent", [], &normalize_entries/1)
    |> Map.update("contains", [], &normalize_entries/1)
    |> Map.update("matches", [], &normalize_entries/1)
    |> Map.update("doc", [], &normalize_entries/1)
    |> Map.update("yaml", [], &normalize_entries/1)
    |> Map.update("json", [], &normalize_entries/1)
    |> Map.update("glob", [], &normalize_entries/1)
    |> Map.update("source_absent", [], &normalize_entries/1)
    |> Map.update("changed_paths_only", [], &normalize_entries/1)
    |> Map.update("repos_clean", [], &normalize_entries/1)
  end

  defp verify_changed_paths_repo({repo, allowed_paths}, repo_index) do
    case repo_root(repo_index, repo) do
      nil -> [missing_repo_report(repo)]
      root -> [changed_paths_report(repo, allowed_paths, root)]
    end
  end

  defp missing_repo_report(repo) do
    %{
      kind: "changed_paths_only",
      repo: repo,
      pass?: false,
      details: "missing_repo"
    }
  end

  defp changed_paths_report(repo, allowed_paths, root) do
    {output, code} =
      System.cmd("git", ["status", "--porcelain"], cd: root, stderr_to_stdout: true)

    changed_paths = changed_paths(output, code)
    disallowed = Enum.reject(changed_paths, &(&1 in allowed_paths))

    %{
      kind: "changed_paths_only",
      repo: repo,
      allowed_paths: allowed_paths,
      changed_paths: changed_paths,
      pass?: code == 0 and disallowed == [],
      details: changed_paths_details(code, output, disallowed)
    }
  end

  defp changed_paths(output, 0) do
    output
    |> String.split("\n", trim: true)
    |> Enum.map(&String.slice(&1, 3..-1//1))
  end

  defp changed_paths(_output, _code), do: []

  defp changed_paths_details(0, _output, []), do: "ok"

  defp changed_paths_details(0, _output, disallowed) do
    "disallowed: #{Enum.join(disallowed, ", ")}"
  end

  defp changed_paths_details(_code, output, _disallowed), do: String.trim(output)

  defp normalize_entries(nil), do: []
  defp normalize_entries(entries) when is_list(entries), do: Enum.map(entries, &normalize_entry/1)
  defp normalize_entries(entry), do: [normalize_entry(entry)]

  defp normalize_entry(value) when is_map(value), do: stringify_keys(value)
  defp normalize_entry(value), do: value

  defp repo_index(%Plan{} = plan) do
    target_repos = plan.config.target_repos || []
    artifacts = (plan.options || %{})[:artifacts] || %{}

    repos =
      target_repos
      |> Enum.map(fn repo -> {repo.name, repo.path} end)
      |> Map.new()
      |> Map.put("packet", plan.source_root)

    Enum.reduce(artifacts, repos, fn {id, path}, acc ->
      Map.put(acc, "@artifact:#{id}", path)
    end)
  end

  defp default_scope(%Plan{} = plan, prompt, repo_index) do
    case Config.llm_for_prompt(plan.config, prompt).cwd do
      cwd when is_binary(cwd) -> cwd
      _ -> Map.get(repo_index, "packet", plan.source_root)
    end
  end

  defp resolve_entry(%{"repo" => repo, "path" => path}, repo_index, _default_scope) do
    root = repo_root(repo_index, repo)
    %{repo: repo, path: path, resolved_path: Paths.resolve(path, root)}
  end

  defp resolve_entry(%{"path" => path}, repo_index, default_scope) do
    repo = repo_for_scope(repo_index, default_scope)
    %{repo: repo, path: path, resolved_path: Paths.resolve(path, default_scope)}
  end

  defp resolve_entry(value, repo_index, default_scope) when is_binary(value) do
    case String.split(value, ":", parts: 2) do
      [repo, path] ->
        if Map.has_key?(repo_index, repo) do
          %{
            repo: repo,
            path: path,
            resolved_path: Paths.resolve(path, repo_root(repo_index, repo))
          }
        else
          %{
            repo: repo_for_scope(repo_index, default_scope),
            path: value,
            resolved_path: Paths.resolve(value, default_scope)
          }
        end

      _ ->
        %{
          repo: repo_for_scope(repo_index, default_scope),
          path: value,
          resolved_path: Paths.resolve(value, default_scope)
        }
    end
  end

  defp resolve_entry(value, repo_index, default_scope) do
    %{
      repo: repo_for_scope(repo_index, default_scope),
      path: to_string(value),
      resolved_path: Paths.resolve(to_string(value), default_scope)
    }
  end

  defp resolve_content_entry(entry, repo_index, default_scope) when is_map(entry) do
    resolved = resolve_entry(entry, repo_index, default_scope)
    Map.merge(resolved, %{text: entry["text"] || entry["contains"] || ""})
  end

  defp resolve_content_entry(entry, repo_index, default_scope) when is_binary(entry) do
    resolved = resolve_entry(entry, repo_index, default_scope)
    Map.merge(resolved, %{text: ""})
  end

  defp resolve_match_entry(entry, repo_index, default_scope) when is_map(entry) do
    resolved = resolve_entry(entry, repo_index, default_scope)
    Map.merge(resolved, %{pattern: entry["pattern"] || entry["matches"] || ""})
  end

  defp resolve_match_entry(entry, repo_index, default_scope) when is_binary(entry) do
    resolved = resolve_entry(entry, repo_index, default_scope)
    Map.merge(resolved, %{pattern: ""})
  end

  defp resolve_command_entry(entry, repo_index, default_scope) when is_map(entry) do
    repo = entry["repo"]
    root = if(repo, do: repo_root(repo_index, repo), else: default_scope)
    cwd = Paths.resolve(entry["cwd"] || ".", root)
    program = entry["exec"] || entry["program"]

    resolved_command(entry, repo_index, repo, root, cwd, program)
  end

  defp resolve_command_entry(entry, _repo_index, default_scope) when is_binary(entry) do
    %{mode: :legacy_shell, repo: nil, command: entry, cwd: default_scope}
  end

  defp resolved_command(entry, repo_index, repo, root, cwd, program)
       when is_binary(program) and program != "" do
    program = Map.get(repo_index, program, resolve_argv_entry(program, repo_index))

    argv =
      entry
      |> Map.get("args", Map.get(entry, "argv", []))
      |> normalize_argv()
      |> Enum.map(&resolve_argv_entry(&1, repo_index))

    %{
      mode: :structured,
      repo: repo,
      program: program,
      argv: argv,
      command: Enum.map_join([program | argv], " ", &inspect/1),
      cwd: cwd,
      env: normalize_command_env(entry["env"] || %{}),
      timeout_ms: normalize_command_timeout(entry["timeout_ms"]),
      stdout_contains: entry["stdout_contains"],
      stdout_matches: entry["stdout_matches"],
      fault_exit_codes: normalize_exit_codes(entry["fault_exit_codes"]),
      regenerates: normalize_regenerates(entry["regenerates"], root)
    }
  end

  defp resolved_command(entry, _repo_index, repo, _root, cwd, _program) do
    %{
      mode: :legacy_shell,
      repo: repo,
      command: entry["run"] || entry["command"] || "",
      cwd: cwd
    }
  end

  defp normalize_argv(argv) when is_list(argv), do: Enum.map(argv, &to_string/1)
  defp normalize_argv(nil), do: []
  defp normalize_argv(value), do: [to_string(value)]

  defp resolve_argv_entry("@repo:" <> reference = original, repo_index) do
    case String.split(reference, "/", parts: 2) do
      [repo] ->
        Map.get(repo_index, repo, original)

      [repo, path] ->
        case Map.get(repo_index, repo) do
          root when is_binary(root) -> Path.expand(path, root)
          _other -> original
        end
    end
  end

  defp resolve_argv_entry(value, _repo_index), do: value

  defp normalize_command_env(env) when is_map(env) do
    Map.new(env, fn {key, value} -> {to_string(key), to_string(value)} end)
  end

  defp normalize_command_env(_env), do: %{}

  defp normalize_command_timeout(timeout) when is_integer(timeout) and timeout > 0, do: timeout
  defp normalize_command_timeout(_timeout), do: 30_000

  defp normalize_exit_codes(codes) when is_list(codes),
    do: Enum.filter(codes, &(is_integer(&1) and &1 >= 0 and &1 <= 255))

  defp normalize_exit_codes(_codes), do: []

  defp normalize_regenerates(paths, root) when is_list(paths) do
    paths
    |> Enum.map(&to_string/1)
    |> Enum.map(&Paths.resolve(&1, root))
    |> Enum.uniq()
  end

  defp normalize_regenerates(nil, _root), do: []
  defp normalize_regenerates(path, root), do: normalize_regenerates([path], root)

  defp repo_root(_repo_index, nil), do: nil
  defp repo_root(repo_index, repo), do: Map.get(repo_index, repo)

  defp repo_for_scope(repo_index, default_scope) when is_binary(default_scope) do
    Enum.find_value(repo_index, fn
      {"packet", _root} ->
        nil

      {repo, root} when is_binary(root) ->
        if root == default_scope or String.starts_with?(default_scope, root <> "/"), do: repo

      _other ->
        nil
    end)
  end

  defp repo_for_scope(_repo_index, _default_scope), do: nil

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), normalize_value(value)}
    end)
  end

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp doc_label(entry) do
    "doc: #{format_entry_path(entry)} (non-blank; #{Doc.min_lines(entry)} lines advisory)"
  end

  defp format_entry_path(%{"repo" => repo, "path" => path}) when is_binary(repo),
    do: "#{repo}:#{path}"

  defp format_entry_path(%{"path" => path}), do: path
  defp format_entry_path(value) when is_binary(value), do: value
  defp format_entry_path(value), do: inspect(value)

  defp format_command(%{"repo" => repo, "run" => command}) when is_binary(repo),
    do: "#{repo}: #{command}"

  defp format_command(%{"command" => command}), do: command
  defp format_command(%{"run" => command}), do: command
  defp format_command(value) when is_binary(value), do: value
  defp format_command(value), do: inspect(value)
end
