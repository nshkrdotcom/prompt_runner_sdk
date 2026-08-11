defmodule PromptRunner.Workspace.Plan do
  @moduledoc "Resolved immutable operator-workspace paths."

  alias PromptRunner.Workspace.Manifest

  @enforce_keys [:manifest, :repositories, :repos_root, :runtime_root]
  defstruct [:manifest, :repositories, :artifacts, :repos_root, :runtime_root, :lock_path]

  @type t :: %__MODULE__{
          manifest: Manifest.t(),
          repositories: %{required(String.t()) => map()},
          artifacts: %{optional(String.t()) => map()},
          repos_root: String.t(),
          runtime_root: String.t(),
          lock_path: String.t()
        }

  @spec build(Manifest.t()) :: t()
  def build(%Manifest{} = manifest) do
    repos_root = Path.join(manifest.workspace_root, "repos")

    repositories =
      Map.new(manifest.repositories, fn {name, repo} ->
        {name, Map.put(repo, :path, Path.join(repos_root, name))}
      end)

    artifacts =
      Map.new(manifest.contract_artifacts, fn artifact ->
        repo = Map.fetch!(repositories, artifact.repo)

        {artifact.id,
         artifact
         |> Map.put(:project_path, Path.expand(artifact.project, repo.path))
         |> Map.put(:path, Path.join([manifest.workspace_root, "artifacts", artifact.id]))}
      end)

    %__MODULE__{
      manifest: manifest,
      repositories: repositories,
      artifacts: artifacts,
      repos_root: repos_root,
      runtime_root: manifest.runtime_root,
      lock_path: Path.join(manifest.workspace_root, "workspace.lock.json")
    }
  end

  @spec repo_overrides(t()) :: [String.t()]
  def repo_overrides(%__MODULE__{repositories: repositories}) do
    repositories
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {name, repo} -> "#{name}:#{repo.path}" end)
  end
end
