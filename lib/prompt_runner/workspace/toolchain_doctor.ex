defmodule PromptRunner.Workspace.ToolchainDoctor do
  @moduledoc """
  Read-only validation of every tool version pin from its exact project cwd.

  The doctor invokes the current operator's `asdf current TOOL` with a
  structured argv. It never starts Mix, compiles a project, installs a runtime,
  or enters a login shell.
  """

  alias CliSubprocessCore.Command
  alias CliSubprocessCore.Command.RunResult
  alias PromptRunner.Workspace.Plan

  @pruned ~w(.git _build deps node_modules .elixir_ls cover)

  @spec check(Plan.t(), keyword()) :: map()
  def check(%Plan{} = plan, opts \\ []) do
    asdf = Keyword.get_lazy(opts, :asdf, fn -> System.find_executable("asdf") end)

    reports =
      plan.repositories
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {repo, spec} ->
        spec.path
        |> tool_version_files()
        |> Enum.flat_map(&file_reports(repo, &1, asdf, opts))
      end)

    %{
      ready?: is_binary(asdf) and Enum.all?(reports, & &1.ready?),
      asdf: asdf,
      projects: reports,
      errors:
        reports
        |> Enum.reject(& &1.ready?)
        |> Enum.map(&Map.take(&1, [:repo, :cwd, :tool, :required, :error]))
    }
  end

  defp tool_version_files(root) do
    if File.dir?(root), do: walk(root), else: []
  end

  defp walk(path) do
    own =
      if File.regular?(Path.join(path, ".tool-versions")),
        do: [Path.join(path, ".tool-versions")],
        else: []

    children =
      case File.ls(path) do
        {:ok, entries} ->
          entries
          |> Enum.reject(&(&1 in @pruned))
          |> Enum.flat_map(&child_version_files(path, &1))

        {:error, _reason} ->
          []
      end

    own ++ children
  end

  defp child_version_files(path, entry) do
    child = Path.join(path, entry)
    if File.dir?(child) and not symlink?(child), do: walk(child), else: []
  end

  defp file_reports(repo, file, asdf, opts) do
    file
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, parts: 2) do
        [tool, version] ->
          [probe(repo, Path.dirname(file), tool, version, asdf, opts)]

        _other ->
          [
            %{
              ready?: false,
              repo: repo,
              cwd: Path.dirname(file),
              tool: nil,
              required: nil,
              error: {:invalid_tool_versions_line, line}
            }
          ]
      end
    end)
  end

  defp probe(repo, cwd, tool, required, nil, _opts) do
    %{ready?: false, repo: repo, cwd: cwd, tool: tool, required: required, error: :asdf_not_found}
  end

  defp probe(repo, cwd, tool, required, asdf, opts) do
    invocation = Command.new(asdf, ["current", tool], cwd: cwd)
    timeout = Keyword.get(opts, :timeout_ms, 10_000)

    result =
      case Command.run(invocation, timeout: timeout, stderr: :stdout) do
        {:ok, %RunResult{} = run_result} ->
          output = String.trim(run_result.output)
          ready? = RunResult.success?(run_result) and pinned_version?(output, required)

          %{
            ready?: ready?,
            resolved: output,
            error:
              if(ready?,
                do: nil,
                else: {:unavailable_or_mismatched, run_result.exit.code, output}
              )
          }

        {:error, error} ->
          %{ready?: false, resolved: nil, error: {:probe_fault, Exception.message(error)}}
      end

    Map.merge(result, %{repo: repo, cwd: cwd, tool: tool, required: required})
  end

  defp pinned_version?(output, required) do
    output
    |> String.split(~r/\s+/)
    |> Enum.any?(&(&1 == required))
  end

  defp symlink?(path), do: match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
end
