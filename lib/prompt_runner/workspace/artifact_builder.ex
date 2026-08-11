defmodule PromptRunner.Workspace.ArtifactBuilder do
  @moduledoc "Builds declared contract artifacts during explicit workspace preparation."

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias PromptRunner.Workspace.Plan

  @spec prepare(Plan.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def prepare(%Plan{} = plan, opts \\ []) do
    plan.artifacts
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce_while({:ok, %{}}, fn {id, artifact}, {:ok, acc} ->
      case build(artifact, opts) do
        {:ok, record} -> {:cont, {:ok, Map.put(acc, id, record)}}
        {:error, reason} -> {:halt, {:error, {:artifact_prepare_failed, id, reason}}}
      end
    end)
  end

  defp build(%{type: "escript"} = artifact, opts) do
    mix_exs = Path.join(artifact.project_path, "mix.exs")
    output = Path.join(artifact.project_path, Path.basename(artifact.project_path))

    if File.exists?(output) do
      {:error, {:artifact_output_preexists, output}}
    else
      try do
        with true <- File.regular?(mix_exs) || {:error, {:missing_mix_project, mix_exs}},
             {:ok, mix} <- executable("mix"),
             invocation =
               Command.new(mix, ["escript.build"],
                 cwd: artifact.project_path,
                 env: %{"MIX_ENV" => "prod"}
               ),
             {:ok, %RunResult{} = result} <-
               Command.run(invocation,
                 timeout: Keyword.get(opts, :artifact_timeout_ms, 300_000),
                 stderr: :stdout
               ),
             true <-
               RunResult.success?(result) ||
                 {:error, {:artifact_build_exit, result.exit.code, String.trim(result.output)}},
             true <- File.regular?(output) || {:error, {:artifact_output_missing, output}},
             :ok <- install(output, artifact.path) do
          {:ok, %{path: artifact.path, type: artifact.type, sha256: digest(artifact.path)}}
        else
          {:error, _reason} = error -> error
        end
      after
        _ = File.rm(output)
      end
    end
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, {:executable_not_found, name}}
      path -> {:ok, path}
    end
  end

  defp install(source, destination) do
    temp = destination <> ".tmp.#{System.unique_integer([:positive, :monotonic])}"

    try do
      with :ok <- File.mkdir_p(Path.dirname(destination)),
           :ok <- File.cp(source, temp),
           :ok <- File.chmod(temp, 0o755) do
        File.rename(temp, destination)
      end
    after
      _ = File.rm(temp)
    end
  end

  defp digest(path) do
    path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
