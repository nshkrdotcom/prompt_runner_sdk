defmodule PromptRunner.PacketLint do
  @moduledoc """
  Static authoring hazards in a packet.

  `packet doctor` reports authoring *gaps* — a packet with no prompts, a prompt
  with no targets. `packet lint` reports authoring *hazards*: constructs that
  load, run, and produce a wrong answer without ever raising. Every check below
  corresponds to an observed way a packet silently misbehaves.

  ## Errors

  Findings that make the packet mean something other than what it says. Each
  one exits non-zero.

  - `prompt_id_filename_mismatch` — prompts are ordered by the numeric filename
    prefix, the sort key built by `PromptRunner.Source.DirectorySource`, not by
    `id:`. A mismatch reorders the run while the front matter still reads
    correctly.
  - `prompt_filename_without_prefix` — with no numeric prefix the file sorts
    last, by basename, among all other unprefixed files.
  - `duplicate_prompt_id` — two prompts claiming one id collide in progress
    state, runtime state, and `run <packet> <id>` selection.
  - `unknown_target_repo` — a target that names no manifest repo contributes no
    working directory and no verifier scope.
  - `unknown_verify_repo` — a verify entry scoped to a repo that does not exist
    resolves against nothing.
  - `repo_group_in_targets` — `@group` syntax is a legacy-config feature.
    `PromptRunner.RepoTargets` is never consulted with packet repo groups, so
    the target expands to nothing.
  - `unknown_verify_clause` — an unrecognized key under `verify:` is parsed,
    stored, and never evaluated, so the contract is weaker than it reads.

  ## Warnings

  Findings that are usually wrong but legitimately intentional sometimes. They
  exit zero unless `strict: true` promotes them.

  - `legacy_shell_command` — a string/`run:` command still asks the legacy
    compatibility path to interpret shell syntax. Strict packets reject it.
  - `verify_command_without_timeout` — a legacy command has no explicit GNU
    timeout wrapper, or a structured command omits `timeout_ms`.
  - `prompt_without_verify` — completion falls back to the provider's own claim
    of success.
  - `contract_without_commands` — the contract has neither a `commands:` entry
    nor any content assertion (`contains`, `matches`, `doc`), so it is
    satisfied by an empty file.
  - `changed_paths_only_vacuous` — `changed_paths_only` reads
    `git status --porcelain`, so it can only see work that is still
    uncommitted. It passes vacuously in any packet where the session commits
    its own work.
  - `inert_front_matter_key` — `references`, `required_reading`, and
    `context_files` are parsed and stored and then never read at runtime.

  Packet lint is intentionally independent of the current checkout state. A
  relative verifier executable may be an output of this prompt or an earlier
  dependency, so existence and executability are evaluated only by the
  post-session verifier.

  ## Legacy timeout detection

  A command counts as bounded when any of its segments — split on `&&`, `||`,
  `;`, and `|` — begins with a `timeout` token. Lint checks that `timeout` is
  invoked at all, not that every branch of a compound command is bounded;
  deciding the latter needs a shell parser.
  """

  alias PromptRunner.AgentControl
  alias PromptRunner.Packet
  alias PromptRunner.Prompt
  alias PromptRunner.Source.PacketSource
  alias PromptRunner.Verifier

  @inert_keys ~w(references required_reading context_files)
  @packet_repo_alias "packet"

  # Clauses that assert something about a file's *content*. A contract holding
  # any of them is not satisfiable by an empty file, so the missing-commands
  # warning would be false.
  @content_clauses ~w(contains matches doc)

  @type finding :: %{
          required(:kind) => String.t(),
          required(:severity) => String.t(),
          required(:message) => String.t(),
          required(:prompt_id) => String.t() | nil,
          required(:file) => String.t() | nil,
          optional(:key) => String.t()
        }

  @type report :: %{
          packet: String.t(),
          root: String.t(),
          strict?: boolean(),
          findings: [finding()],
          errors: non_neg_integer(),
          warnings: non_neg_integer(),
          pass?: boolean()
        }

  @doc """
  Lints the packet rooted at `root`.

  Options:

  - `:strict` — promote every warning to an error.
  """
  @spec lint(String.t(), keyword()) :: {:ok, report()} | {:error, term()}
  def lint(root, opts \\ []) when is_binary(root) do
    with {:ok, packet} <- Packet.load(root),
         {:ok, result} <- PacketSource.load(packet.root, []) do
      {:ok, build_report(packet, result.prompts, opts)}
    end
  end

  defp build_report(packet, prompts, opts) do
    strict? = opts[:strict] == true
    scope = packet_scope(packet)

    findings =
      agent_control_findings(packet, scope)
      |> Kernel.++(duplicate_id_findings(prompts))
      |> Kernel.++(Enum.flat_map(prompts, &prompt_findings(&1, scope)))
      |> Enum.map(&promote(&1, strict?))
      |> Enum.sort_by(&{&1.file || "", &1.kind, &1.message})

    errors = Enum.count(findings, &(&1.severity == "error"))

    %{
      packet: packet.name,
      root: packet.root,
      strict?: strict?,
      findings: findings,
      errors: errors,
      warnings: length(findings) - errors,
      pass?: errors == 0
    }
  end

  defp promote(finding, true), do: %{finding | severity: "error"}
  defp promote(finding, false), do: finding

  defp agent_control_findings(packet, scope) do
    case AgentControl.config(
           Map.get(packet.options, "agent_control", Map.get(packet.options, :agent_control))
         ) do
      {:ok, %{enabled?: false}} ->
        []

      {:ok, %{completion_verify: contract}} ->
        prompt = %Prompt{
          num: "agent-control-finish",
          name: "Agent-control completion",
          file: "prompt_runner_packet.md",
          target_repos: Enum.map(packet.repos, & &1.name),
          verify: contract,
          validation_commands: [],
          metadata: %{}
        }

        contract_findings(prompt, scope)

      {:error, reason} ->
        [
          %{
            kind: "invalid_agent_control",
            severity: "error",
            prompt_id: nil,
            file: "prompt_runner_packet.md",
            message: "agent_control is invalid: #{inspect(reason)}"
          }
        ]
    end
  end

  # Everything the lint needs to answer "where would the runner have run this",
  # mirroring `PromptRunner.Config.llm_for_prompt/2`: a prompt's working
  # directory is its first target repo, or the default repo, or the packet root.
  defp packet_scope(packet) do
    %{
      repo_names: Enum.map(packet.repos, & &1.name),
      repo_paths:
        packet.repos
        |> Map.new(&{&1.name, &1.path})
        |> Map.put(@packet_repo_alias, packet.root),
      default_path:
        case Enum.find(packet.repos, & &1.default) do
          %{path: path} -> path
          _ -> packet.root
        end
    }
  end

  defp prompt_findings(prompt, scope) do
    filename_findings(prompt) ++
      target_findings(prompt, scope.repo_names) ++
      contract_findings(prompt, scope) ++
      inert_key_findings(prompt)
  end

  # -- identity and ordering

  defp duplicate_id_findings(prompts) do
    prompts
    |> Enum.group_by(& &1.num)
    |> Enum.filter(fn {_num, group} -> length(group) > 1 end)
    |> Enum.sort_by(fn {num, _group} -> num end)
    |> Enum.map(fn {num, group} -> duplicate_id_finding(num, group) end)
  end

  defp duplicate_id_finding(num, group) do
    files = group |> Enum.map(& &1.file) |> Enum.sort() |> Enum.join(", ")

    %{
      kind: "duplicate_prompt_id",
      severity: "error",
      prompt_id: num,
      file: nil,
      message:
        "duplicate prompt id #{inspect(num)} in #{files}; progress state, runtime state, " <>
          "and single-prompt selection are all keyed by id"
    }
  end

  defp filename_findings(%{file: file} = prompt) when is_binary(file) do
    case filename_prefix(file) do
      nil ->
        [
          finding(
            "error",
            "prompt_filename_without_prefix",
            prompt,
            "prompt filename has no numeric prefix, so it sorts last by basename; " <>
              "prompts are ordered by the filename prefix, not by id:"
          )
        ]

      prefix ->
        id_mismatch_finding(prompt, prefix)
    end
  end

  defp filename_findings(_prompt), do: []

  defp id_mismatch_finding(%{num: num}, prefix) when num == prefix, do: []

  defp id_mismatch_finding(prompt, prefix) do
    [
      finding(
        "error",
        "prompt_id_filename_mismatch",
        prompt,
        "prompt id #{inspect(prompt.num)} does not match the filename numeric prefix " <>
          "#{inspect(prefix)}; ordering is by filename, so the declared id never reaches " <>
          "the schedule"
      )
    ]
  end

  defp filename_prefix(file) do
    case Regex.run(~r/^(\d+)/, Path.basename(file), capture: :all_but_first) do
      [prefix] ->
        prefix |> String.to_integer() |> Integer.to_string() |> String.pad_leading(2, "0")

      _other ->
        nil
    end
  end

  # -- targets

  defp target_findings(%{target_repos: targets} = prompt, repo_names) when is_list(targets) do
    Enum.flat_map(targets, &target_finding(&1, prompt, repo_names))
  end

  defp target_findings(_prompt, _repo_names), do: []

  defp target_finding("@" <> group, prompt, _repo_names) do
    [
      finding(
        "error",
        "repo_group_in_targets",
        prompt,
        "targets uses the repo group syntax \"@#{group}\"; repo groups are a legacy-config " <>
          "feature and are never expanded for packets, so the target resolves to nothing"
      )
    ]
  end

  defp target_finding(target, prompt, repo_names) when is_binary(target) do
    if target in repo_names do
      []
    else
      [
        finding(
          "error",
          "unknown_target_repo",
          prompt,
          "targets names #{inspect(target)}, which is not a repo in the packet manifest " <>
            "(known: #{known_repos(repo_names)})"
        )
      ]
    end
  end

  defp target_finding(_target, _prompt, _repo_names), do: []

  defp known_repos([]), do: "(none)"
  defp known_repos(repo_names), do: Enum.join(repo_names, ", ")

  # -- contract

  defp contract_findings(prompt, scope) do
    contract = prompt.verify || %{}

    empty_contract_findings(prompt, contract) ++
      unknown_clause_findings(prompt, contract) ++
      command_findings(prompt, contract, scope) ++
      verify_repo_findings(prompt, contract, scope.repo_names) ++
      changed_paths_findings(prompt, contract)
  end

  defp empty_contract_findings(prompt, contract) do
    if Verifier.contract_items(contract) == [] do
      [
        finding(
          "warning",
          "prompt_without_verify",
          prompt,
          "prompt has no verify contract, so completion is owned by the provider's own claim " <>
            "of success rather than by a deterministic check"
        )
      ]
    else
      []
    end
  end

  defp unknown_clause_findings(prompt, contract) do
    contract
    |> Map.keys()
    |> Enum.reject(&(to_string(&1) in Verifier.contract_keys()))
    |> Enum.sort()
    |> Enum.map(fn key ->
      finding(
        "error",
        "unknown_verify_clause",
        prompt,
        "verify contract has an unrecognized clause #{inspect(to_string(key))}; it is parsed, " <>
          "stored, and never evaluated (known clauses: #{Enum.join(Verifier.contract_keys(), ", ")})"
      )
    end)
  end

  defp command_findings(prompt, contract, _scope) do
    case clause_entries(contract, "commands") do
      [] ->
        missing_commands_finding(prompt, contract)

      entries ->
        Enum.flat_map(entries, fn entry ->
          legacy_shell_finding(entry, prompt) ++
            command_timeout_finding(entry, prompt)
        end)
    end
  end

  defp missing_commands_finding(prompt, contract) do
    if Verifier.contract_items(contract) == [] or content_asserted?(contract) do
      []
    else
      [
        finding(
          "warning",
          "contract_without_commands",
          prompt,
          "verify contract has no commands: entry and no content assertion " <>
            "(#{Enum.join(@content_clauses, "/")}); files_exist alone is satisfied by an " <>
            "empty file, so the contract cannot tell a finished artifact from a touched one"
        )
      ]
    end
  end

  defp content_asserted?(contract) do
    Enum.any?(@content_clauses, &(clause_entries(contract, &1) != []))
  end

  defp command_timeout_finding(entry, prompt) do
    case structured_command(entry) do
      %{timeout_ms: timeout} when is_integer(timeout) and timeout > 0 -> []
      %{} -> structured_timeout_finding(entry, prompt)
      nil -> legacy_command_timeout_finding(entry, prompt)
    end
  end

  defp legacy_command_timeout_finding(entry, prompt) do
    case command_string(entry) do
      nil -> []
      command -> unwrapped_command_finding(command, prompt)
    end
  end

  defp structured_timeout_finding(entry, prompt) do
    [
      finding(
        "warning",
        "verify_command_without_timeout",
        prompt,
        "structured verify command has no positive timeout_ms: #{inspect(entry)}"
      )
    ]
  end

  defp unwrapped_command_finding(command, prompt) do
    if timeout_wrapped?(command) do
      []
    else
      [
        finding(
          "warning",
          "verify_command_without_timeout",
          prompt,
          "legacy verify command has no timeout wrapper: #{inspect(command)}"
        )
      ]
    end
  end

  defp command_string(%{"run" => run}) when is_binary(run), do: run
  defp command_string(%{"command" => command}) when is_binary(command), do: command
  defp command_string(entry) when is_binary(entry), do: entry
  defp command_string(_entry), do: nil

  defp structured_command(%{} = entry) do
    case entry["exec"] || entry["program"] do
      program when is_binary(program) and program != "" ->
        %{program: program, timeout_ms: entry["timeout_ms"]}

      _other ->
        nil
    end
  end

  defp structured_command(_entry), do: nil

  defp legacy_shell_finding(entry, prompt) do
    if is_binary(command_string(entry)) and is_nil(structured_command(entry)) do
      [
        finding(
          "warning",
          "legacy_shell_command",
          prompt,
          "verify command uses the legacy shell compatibility path; use exec/program plus args/argv"
        )
      ]
    else
      []
    end
  end

  defp timeout_wrapped?(command) do
    command
    |> String.split(~r/\|\||&&|;|\|/)
    |> Enum.any?(&segment_timeout?/1)
  end

  defp segment_timeout?(segment) do
    case segment |> String.trim() |> String.split(~r/\s+/, parts: 2) do
      [token | _rest] -> token == "timeout" or String.ends_with?(token, "/timeout")
      [] -> false
    end
  end

  defp verify_repo_findings(prompt, contract, repo_names) do
    Enum.flat_map(contract, fn {clause, entries} ->
      entries
      |> List.wrap()
      |> Enum.flat_map(&entry_repo_finding(&1, to_string(clause), prompt, repo_names))
    end)
  end

  defp entry_repo_finding(%{"repo" => repo}, clause, prompt, repo_names) when is_binary(repo) do
    if repo in repo_names or repo == @packet_repo_alias do
      []
    else
      [
        finding(
          "error",
          "unknown_verify_repo",
          prompt,
          "verify.#{clause} entry names repo #{inspect(repo)}, which is not a repo in the " <>
            "packet manifest (known: #{known_repos(repo_names ++ [@packet_repo_alias])})"
        )
      ]
    end
  end

  defp entry_repo_finding(_entry, _clause, _prompt, _repo_names), do: []

  # Unconditional, because lint cannot see how the packet is run and a check
  # that only fires once someone has already configured the thing correctly is
  # close to useless. The wording has to let a legitimate user dismiss it in one
  # read, so it names the mechanism and the exact condition under which the
  # clause still works.
  defp changed_paths_findings(prompt, contract) do
    case clause_entries(contract, "changed_paths_only") do
      [] ->
        []

      _entries ->
        [
          finding(
            "warning",
            "changed_paths_only_vacuous",
            prompt,
            "changed_paths_only reads git status --porcelain, so it only ever sees work " <>
              "that is still uncommitted. It is correct when the runner owns the commit, " <>
              "and it passes vacuously whenever the session commits its own work instead " <>
              "(--no-commit, committer: noop, or standing instructions telling the agent " <>
              "to commit), because the tree is already clean when the verifier runs. If " <>
              "the runner commits for this packet, ignore this; otherwise use repos_clean:"
          )
        ]
    end
  end

  defp clause_entries(contract, clause) do
    contract
    |> Map.get(clause, [])
    |> List.wrap()
  end

  # -- inert front matter

  defp inert_key_findings(prompt) do
    metadata = prompt.metadata || %{}

    @inert_keys
    |> Enum.filter(&Map.has_key?(metadata, &1))
    |> Enum.map(fn key ->
      "warning"
      |> finding("inert_front_matter_key", prompt, inert_message(key))
      |> Map.put(:key, key)
    end)
  end

  defp inert_message(key) do
    "`#{key}` is parsed and stored on the prompt and then never read: it is never sent to " <>
      "the provider and never used for ordering. Only the markdown body after the front " <>
      "matter reaches the model, so write the paths into the body"
  end

  defp finding(severity, kind, prompt, message) do
    %{
      kind: kind,
      severity: severity,
      prompt_id: prompt.num,
      file: prompt.file,
      message: message
    }
  end
end
