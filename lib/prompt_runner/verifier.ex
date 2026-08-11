defmodule PromptRunner.Verifier do
  @moduledoc """
  Deterministic prompt verification.
  """

  alias PromptRunner.Config
  alias PromptRunner.Control.Amendment
  alias PromptRunner.Paths
  alias PromptRunner.Plan
  alias PromptRunner.Verifier.Doc
  alias PromptRunner.Verifier.ReposClean

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
  # `bash -lc` reports 127 for a command it could not find and 126 for one it
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

    items =
      []
      |> Kernel.++(verify_files_exist(contract, repo_index, default_scope))
      |> Kernel.++(verify_files_absent(contract, repo_index, default_scope))
      |> Kernel.++(verify_contains(contract, repo_index, default_scope))
      |> Kernel.++(verify_matches(contract, repo_index, default_scope))
      |> Kernel.++(verify_doc(contract, repo_index, default_scope))
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

  defp amendment_records(%Plan{source_root: source_root}, prompt, opts)
       when is_binary(source_root) do
    if Keyword.get(opts, :amendments, true) do
      Amendment.read(source_root, prompt.num)
    else
      []
    end
  end

  defp amendment_records(_plan, _prompt, _opts), do: []

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
      %{repo: repo, command: command, cwd: cwd} =
        resolve_command_entry(entry, repo_index, default_scope)

      {output, code} = System.cmd("bash", ["-lc", command], cd: cwd, stderr_to_stdout: true)
      fault = Map.get(@fault_exit_codes, code)

      %{
        kind: "command",
        repo: repo,
        command: command,
        cwd: cwd,
        exit_code: code,
        fault: fault,
        pass?: code == 0,
        details: command_details(fault, code, output)
      }
    end)
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

    target_repos
    |> Enum.map(fn repo -> {repo.name, repo.path} end)
    |> Map.new()
    |> Map.put("packet", plan.source_root)
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
    cwd = if(repo, do: repo_root(repo_index, repo), else: default_scope)
    %{repo: repo, command: entry["run"] || entry["command"] || "", cwd: cwd}
  end

  defp resolve_command_entry(entry, _repo_index, default_scope) when is_binary(entry) do
    %{repo: nil, command: entry, cwd: default_scope}
  end

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
    "doc: #{format_entry_path(entry)} (>= #{Doc.min_lines(entry)} non-blank lines)"
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
