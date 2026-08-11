defmodule PromptRunner.Control.Interventions do
  @moduledoc """
  The append-only record of what a human said to a run, kept with the packet.

  `packet/.prompt_runner/interventions/<prompt>.jsonl`, one object per steer:
  timestamp, prompt, attempt, author, text, and the lane it was delivered on.

  Separate from run state on purpose. Run state is runtime detail that
  disappears with the state file; this lives with the prompt configuration and
  is committed alongside the work, so a steer is timestamped by a commit — the
  same property the claim ladder already relies on for pre-registration.

  A steer is never evidence about the work. A contract asserting that a
  document contains X is not satisfied by a human having said "put X in the
  doc"; the verifier sees what the session produced. This file exists so that a
  reader can tell a human-guided result from an autonomous one — which is a
  flag, not a disqualification.
  """

  alias PromptRunner.Paths

  @dir ".prompt_runner"
  @interventions "interventions"
  @type root :: String.t() | {:state_root, String.t()}

  @type intervention :: %{
          required(:at) => DateTime.t(),
          required(:prompt_id) => String.t(),
          required(:attempt) => pos_integer() | nil,
          required(:author) => String.t() | nil,
          required(:text) => String.t(),
          required(:lane) => atom() | String.t() | nil,
          required(:delivery) => atom() | String.t() | nil,
          optional(:run_id) => String.t() | nil
        }

  @spec dir(root()) :: String.t()
  def dir({:state_root, state_root}) when is_binary(state_root) do
    state_root |> Paths.resolve() |> Path.join(@interventions)
  end

  def dir(packet_dir) when is_binary(packet_dir) do
    packet_dir |> Paths.resolve() |> Path.join(@dir) |> Path.join(@interventions)
  end

  @spec path(root(), String.t()) :: String.t()
  def path(root, prompt_id) when is_binary(prompt_id) do
    Path.join(dir(root), "#{prompt_id}.jsonl")
  end

  @doc """
  Appends one steer to the prompt's intervention log.
  """
  @spec append(root(), intervention()) :: :ok | {:error, term()}
  def append(root, record) when is_map(record) do
    file = path(root, record.prompt_id)

    with :ok <- File.mkdir_p(Path.dirname(file)) do
      File.write(file, Jason.encode!(encode(record)) <> "\n", [:append])
    end
  end

  @doc """
  Every steer recorded for one prompt, oldest first.
  """
  @spec read(root(), String.t()) :: [map()]
  def read(root, prompt_id) do
    root
    |> path(prompt_id)
    |> File.read()
    |> case do
      {:ok, content} -> content |> String.split("\n", trim: true) |> Enum.flat_map(&decode/1)
      {:error, _reason} -> []
    end
  end

  @doc """
  How many steers this prompt has taken.

  Read from the committed artifact rather than from run state, so it survives a
  state file being deleted and a resume in a fresh checkout.
  """
  @spec count(root(), String.t()) :: non_neg_integer()
  def count(root, prompt_id), do: root |> read(prompt_id) |> length()

  defp encode(record) do
    %{
      "at" => DateTime.to_iso8601(record.at),
      "prompt" => record.prompt_id,
      "attempt" => record.attempt,
      "author" => record.author,
      "text" => record.text,
      "lane" => record.lane && to_string(record.lane),
      "delivery" => record.delivery && to_string(record.delivery),
      "run_id" => Map.get(record, :run_id)
    }
  end

  defp decode(line) do
    case Jason.decode(line) do
      {:ok, map} when is_map(map) -> [map]
      _other -> []
    end
  end
end
