defmodule PromptRunner.Control.Amendment do
  @moduledoc """
  Changing what "done" means for a prompt, on the record.

  An amendment adds, removes, or modifies a clause of a prompt's verify
  contract. It is the one capability in this program that can make a completed
  prompt mean something other than what the packet says, so it is governed more
  tightly than steering, which cannot.

  ## Timing is part of the meaning

  Claims in these programs are pre-registered by git commit timestamp precisely
  so nobody can decide what they were proving after seeing the result. An
  amendment that *weakens* a contract after a verify failure is exactly the
  move pre-registration exists to prevent. So the record distinguishes:

  - `:pre_verify` — before any verify attempt has run. Ordinary scope
    correction.
  - `:post_failure` — after a verify failure. Suspect by default.
  - `:post_success` — after a verify pass. Also after the fact, and named
    honestly rather than folded into either of the other two.

  An amendment log that does not say *when, relative to verification* is not an
  audit trail.

  ## Asymmetric by design

  Adding a requirement is routine. Removing or relaxing one is the risky
  direction, and takes a different verb — `PromptRunner.Control.relax/3`, with
  an explicit confirmation — never a different argument to the same command.

  ## Run-local by default

  The packet file stays authoritative. A future re-run from clean state uses
  the original contract. Writing back to the packet is a separate explicit act,
  because a packet is a versioned artifact and editing it is a commit, not a
  side effect.
  """

  alias PromptRunner.Paths
  alias PromptRunner.Verifier

  @dir ".prompt_runner"
  @amendments "amendments"

  @type phase :: :pre_verify | :post_failure | :post_success

  @type t :: %{
          required(:at) => DateTime.t(),
          required(:prompt_id) => String.t(),
          required(:author) => String.t() | nil,
          required(:reason) => String.t(),
          required(:phase) => phase(),
          required(:direction) => :add | :relax,
          required(:clause) => String.t(),
          required(:operation) => :add | :drop | :replace,
          optional(:entries) => [term()],
          optional(:run_id) => String.t() | nil,
          optional(:persisted) => boolean()
        }

  @spec dir(String.t()) :: String.t()
  def dir(packet_dir) when is_binary(packet_dir) do
    packet_dir |> Paths.resolve() |> Path.join(@dir) |> Path.join(@amendments)
  end

  @spec path(String.t(), String.t()) :: String.t()
  def path(packet_dir, prompt_id), do: Path.join(dir(packet_dir), "#{prompt_id}.jsonl")

  @doc """
  Appends one amendment to the prompt's amendment log.
  """
  @spec append(String.t(), t()) :: :ok | {:error, term()}
  def append(packet_dir, amendment) when is_binary(packet_dir) and is_map(amendment) do
    file = path(packet_dir, amendment.prompt_id)

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, Jason.encode!(encode(amendment)) <> "\n", [:append])
    end
  end

  @doc """
  Every amendment recorded for one prompt, oldest first.
  """
  @spec read(String.t(), String.t()) :: [map()]
  def read(packet_dir, prompt_id) do
    packet_dir
    |> path(prompt_id)
    |> File.read()
    |> case do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _reason} -> []
    end
  end

  @doc """
  Applies every recorded amendment for a prompt to its packet contract.

  This is what the verifier is handed. The packet's own contract is never
  mutated in place — it is the input to this function, and re-reading the
  packet gives it back unchanged.
  """
  @spec enforced_contract(map(), [map()]) :: map()
  def enforced_contract(packet_contract, amendments) when is_map(packet_contract) do
    Enum.reduce(amendments, stringify(packet_contract), &apply_amendment/2)
  end

  @doc """
  Builds an amendment record, refusing the ones that must not be silent.

  A missing reason is refused rather than defaulted: an amendment with no
  stated reason is not an audit trail entry, it is a hole in one.
  """
  @spec build(keyword()) :: {:ok, t()} | {:error, term()}
  def build(opts) do
    clause = opts |> Keyword.get(:clause) |> to_string()
    reason = Keyword.get(opts, :reason)

    cond do
      not (is_binary(reason) and String.trim(reason) != "") ->
        {:error, :reason_required}

      clause not in Verifier.contract_keys() ->
        {:error, {:unknown_clause, clause}}

      true ->
        {:ok,
         %{
           at: DateTime.utc_now(),
           prompt_id: Keyword.fetch!(opts, :prompt_id),
           author: Keyword.get(opts, :author),
           reason: String.trim(reason),
           phase: Keyword.get(opts, :phase, :pre_verify),
           direction: Keyword.get(opts, :direction, :add),
           clause: clause,
           operation: Keyword.get(opts, :operation, :add),
           entries: Keyword.get(opts, :entries, []),
           run_id: Keyword.get(opts, :run_id),
           persisted: Keyword.get(opts, :persisted, false)
         }}
    end
  end

  @doc """
  A readable packet-versus-enforced diff for one prompt.

  If you cannot show the diff, you do not have the audit.
  """
  @spec diff(map(), map()) :: [{:same | :added | :removed, String.t(), String.t()}]
  def diff(packet_contract, enforced_contract) do
    packet = clause_map(packet_contract)
    enforced = clause_map(enforced_contract)

    (Map.keys(packet) ++ Map.keys(enforced))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&clause_diff(&1, Map.get(packet, &1, []), Map.get(enforced, &1, [])))
  end

  defp clause_diff(clause, packet_entries, enforced_entries) do
    removed = packet_entries -- enforced_entries
    added = enforced_entries -- packet_entries
    same = packet_entries -- removed

    Enum.map(same, &{:same, clause, &1}) ++
      Enum.map(removed, &{:removed, clause, &1}) ++
      Enum.map(added, &{:added, clause, &1})
  end

  defp clause_map(contract) when is_map(contract) do
    contract
    |> stringify()
    |> Map.new(fn {clause, entries} -> {clause, entries |> List.wrap() |> Enum.map(&label/1)} end)
  end

  defp clause_map(_contract), do: %{}

  defp label(entry) when is_binary(entry), do: entry

  defp label(entry) when is_map(entry) do
    entry
    |> Enum.sort()
    |> Enum.map_join(" ", fn {key, value} -> "#{key}=#{inspect(value)}" end)
  end

  defp label(entry), do: inspect(entry)

  # -- applying

  defp apply_amendment(%{"operation" => "drop", "clause" => clause}, contract),
    do: Map.delete(contract, clause)

  defp apply_amendment(%{"operation" => "replace"} = amendment, contract),
    do: Map.put(contract, amendment["clause"], amendment["entries"] || [])

  defp apply_amendment(%{"operation" => "add"} = amendment, contract) do
    clause = amendment["clause"]
    existing = contract |> Map.get(clause, []) |> List.wrap()
    Map.put(contract, clause, existing ++ List.wrap(amendment["entries"] || []))
  end

  defp apply_amendment(_amendment, contract), do: contract

  defp encode(amendment) do
    %{
      "at" => DateTime.to_iso8601(amendment.at),
      "prompt" => amendment.prompt_id,
      "author" => amendment.author,
      "reason" => amendment.reason,
      "phase" => to_string(amendment.phase),
      "direction" => to_string(amendment.direction),
      "clause" => amendment.clause,
      "operation" => to_string(amendment.operation),
      "entries" => Map.get(amendment, :entries, []),
      "run_id" => Map.get(amendment, :run_id),
      "persisted" => Map.get(amendment, :persisted, false)
    }
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _other -> []
    end
  end

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), value} end)
end
