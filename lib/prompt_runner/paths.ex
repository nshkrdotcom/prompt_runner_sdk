defmodule PromptRunner.Paths do
  @moduledoc false

  @state_dir ".prompt_runner"
  @pid_file "run.pid"
  @log_dir "logs"

  @doc "Packet-local runtime state directory."
  @spec state_dir(String.t()) :: String.t()
  def state_dir(packet_dir) when is_binary(packet_dir),
    do: packet_dir |> resolve() |> Path.join(@state_dir)

  @doc "Log directory inside a runtime state directory."
  @spec log_dir(String.t()) :: String.t()
  def log_dir(state_dir) when is_binary(state_dir), do: Path.join(state_dir, @log_dir)

  @doc """
  Path of the run pid file inside a runtime state directory.

  The runner writes it for the duration of a run so supervision can check
  liveness by signalling a pid rather than by matching a process name.
  """
  @spec pid_file(String.t()) :: String.t()
  def pid_file(state_dir) when is_binary(state_dir), do: Path.join(state_dir, @pid_file)

  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(path, base_dir \\ nil)

  def resolve(nil, _base_dir), do: nil

  def resolve(path, base_dir) when is_binary(path) do
    path
    |> expand(base_dir)
    |> canonicalize()
  end

  defp expand(path, base_dir) do
    cond do
      Path.type(path) == :absolute -> Path.expand(path)
      is_binary(base_dir) -> Path.expand(path, base_dir)
      true -> Path.expand(path)
    end
  end

  defp canonicalize(path) do
    case Path.split(path) do
      [root | rest] -> walk(root, rest)
      [] -> path
    end
  end

  defp walk(current, []), do: current

  defp walk(current, [segment | rest]) do
    candidate = Path.join(current, segment)

    case File.lstat(candidate) do
      {:ok, %File.Stat{type: :symlink}} ->
        candidate
        |> resolve_link_target()
        |> walk(rest)

      {:ok, _stat} ->
        walk(candidate, rest)

      {:error, _reason} ->
        Path.join(current, Path.join([segment | rest]))
    end
  end

  defp resolve_link_target(path) do
    case File.read_link(path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute do
            Path.expand(target)
          else
            Path.expand(target, Path.dirname(path))
          end

        canonicalize(target)

      {:error, _reason} ->
        path
    end
  end
end
