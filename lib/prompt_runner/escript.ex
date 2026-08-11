defmodule PromptRunner.Escript do
  @moduledoc """
  Bootstraps the installed escript without depending on a source checkout.

  `erlexec` ships a native port executable. Mix embeds that private artifact in
  the escript archive, but native programs must exist as ordinary executable
  files before the OS can launch them. The bootstrap extracts the exact
  digest-addressed port into the current operator's cache, configures erlexec
  before application startup, and then delegates to `PromptRunner.CLI`.
  """

  alias PromptRunner.Escript.NativePort

  @spec main([String.t()]) :: :ok | no_return()
  def main(args) do
    with {:ok, port_executable} <- NativePort.prepare(:escript.script_name()),
         :ok <- Application.put_env(:erlexec, :portexe, port_executable, persistent: true),
         {:ok, _started} <- Application.ensure_all_started(:prompt_runner_sdk) do
      PromptRunner.CLI.main(args)
    else
      {:error, reason} -> halt(reason)
    end
  end

  @spec halt(term()) :: no_return()
  defp halt(reason) do
    IO.puts(:stderr, "ERROR: installed Prompt Runner could not start: #{inspect(reason)}")
    System.halt(1)
  end
end

defmodule PromptRunner.Escript.NativePort do
  @moduledoc false

  @spec prepare(charlist()) :: {:ok, String.t()} | {:error, term()}
  def prepare(script_name) when is_list(script_name) and script_name != [] do
    with {:ok, entries} <- extract(script_name),
         {:ok, archive_path, contents} <- select_entry(entries),
         digest = sha256(contents),
         destination = destination(archive_path, digest),
         :ok <- materialize(destination, contents, digest) do
      {:ok, destination}
    end
  end

  def prepare(script_name), do: {:error, {:invalid_escript_path, script_name}}

  defp extract(script_name) do
    case :escript.extract(script_name, []) do
      {:ok, sections} -> extract_archive(sections)
      {:error, reason} -> {:error, {:escript_extract_failed, reason}}
    end
  end

  defp extract_archive(sections) do
    with {:ok, archive} <- Keyword.fetch(sections, :archive),
         {:ok, entries} <- :zip.unzip(archive, [:memory]) do
      {:ok, entries}
    else
      :error -> {:error, :escript_archive_missing}
      {:error, reason} -> {:error, {:escript_archive_invalid, reason}}
    end
  end

  defp select_entry(entries) do
    candidates =
      entries
      |> Enum.flat_map(&entry/1)
      |> Enum.filter(fn {path, _contents} -> String.ends_with?(path, "/exec-port") end)

    architecture = :erlang.system_info(:system_architecture) |> List.to_string()
    matching = Enum.filter(candidates, fn {path, _contents} -> path =~ architecture end)

    case {matching, candidates} do
      {[candidate], _all} -> selected(candidate)
      {[], [candidate]} -> selected(candidate)
      {[], []} -> {:error, :erlexec_port_not_embedded}
      _other -> {:error, {:ambiguous_erlexec_ports, Enum.map(candidates, &elem(&1, 0))}}
    end
  end

  defp entry({path, contents}) when is_list(path) and is_binary(contents) do
    [{List.to_string(path), contents}]
  end

  defp entry({path, _info, contents}) when is_list(path) and is_binary(contents) do
    [{List.to_string(path), contents}]
  end

  defp entry(_other), do: []

  defp selected({path, contents}), do: {:ok, path, contents}

  defp destination(archive_path, digest) do
    architecture = archive_path |> Path.dirname() |> Path.basename()
    cache = System.get_env("XDG_CACHE_HOME") || Path.join(System.user_home!(), ".cache")

    Path.join([
      cache,
      "prompt_runner",
      "native",
      PromptRunner.version(),
      architecture,
      digest,
      "exec-port"
    ])
  end

  defp materialize(path, contents, digest) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> verify_existing(path, digest)
      {:ok, stat} -> {:error, {:native_port_not_regular, path, stat.type}}
      {:error, :enoent} -> create(path, contents, digest)
      {:error, reason} -> {:error, {:native_port_stat_failed, path, reason}}
    end
  end

  defp verify_existing(path, digest) do
    case File.read(path) do
      {:ok, contents} ->
        if sha256(contents) == digest,
          do: ensure_executable(path),
          else: {:error, {:native_port_digest_mismatch, path}}

      {:error, reason} ->
        {:error, {:native_port_read_failed, path, reason}}
    end
  end

  defp create(path, contents, digest) do
    temp = path <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           :ok <- File.write(temp, contents, [:binary, :sync]),
           :ok <- File.chmod(temp, 0o700),
           :ok <- install_exclusive(temp, path),
           :ok <- verify_existing(path, digest) do
        :ok
      else
        {:error, reason} -> {:error, {:native_port_install_failed, path, reason}}
      end
    after
      _ = File.rm(temp)
    end
  end

  defp install_exclusive(temp, path) do
    case File.ln(temp, path) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_executable(path) do
    case File.stat(path) do
      {:ok, stat} when Bitwise.band(stat.mode, 0o100) != 0 -> :ok
      {:ok, _stat} -> File.chmod(path, 0o700)
      {:error, reason} -> {:error, {:native_port_stat_failed, path, reason}}
    end
  end

  defp sha256(contents) do
    :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
  end
end
