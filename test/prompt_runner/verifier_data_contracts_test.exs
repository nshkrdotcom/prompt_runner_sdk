defmodule PromptRunner.VerifierDataContractsTest do
  use ExUnit.Case, async: true

  alias PromptRunner.{Config, Plan, Prompt, Verifier}
  alias PromptRunner.Test.FSHelpers

  setup do
    repo = FSHelpers.tmp_dir("prompt_runner_data_contracts")
    on_exit(fn -> File.rm_rf!(repo) end)

    config = %Config{target_repos: [%{name: "app", path: repo}], project_dir: repo}
    {:ok, repo: repo, plan: %Plan{config: config, source_root: repo}}
  end

  test "YAML, JSON shape, and glob checks return structured evidence", %{repo: repo, plan: plan} do
    File.write!(Path.join(repo, "config.yml"), "name: example\n")

    File.write!(
      Path.join(repo, "matrix.json"),
      Jason.encode!(%{"projects" => [%{"project" => "app", "status" => "ok"}]})
    )

    File.mkdir_p!(Path.join(repo, "artifacts"))
    File.write!(Path.join(repo, "artifacts/result.txt"), "result\n")

    prompt = %Prompt{
      num: "01",
      name: "Data",
      target_repos: ["app"],
      verify: %{
        "yaml" => [%{"path" => "config.yml", "root" => "map"}],
        "json" => [
          %{
            "path" => "matrix.json",
            "root" => "map",
            "non_empty_paths" => ["projects"],
            "array_items_require" => %{"projects" => ["project", "status"]},
            "array_none_match" => [
              %{"path" => "projects", "field" => "status", "equals" => "fail"}
            ]
          }
        ],
        "glob" => [%{"path" => "artifacts/*.txt", "min_matches" => 1, "non_empty" => true}]
      }
    }

    report = Verifier.verify_prompt(plan, prompt)
    assert report.pass?
    assert Enum.map(report.items, & &1.kind) == ~w(yaml json glob)
  end

  test "JSON violations are assertion failures, not infrastructure faults", %{
    repo: repo,
    plan: plan
  } do
    File.write!(
      Path.join(repo, "matrix.json"),
      Jason.encode!(%{"projects" => [%{"status" => "fail"}]})
    )

    prompt = %Prompt{
      num: "01",
      name: "Data",
      target_repos: ["app"],
      verify: %{
        "json" => [
          %{
            "path" => "matrix.json",
            "array_items_require" => %{"projects" => ["project", "status"]},
            "array_none_match" => [
              %{"path" => "projects", "field" => "status", "equals" => "fail"}
            ]
          }
        ]
      }
    }

    report = Verifier.verify_prompt(plan, prompt)
    refute report.pass?
    assert report.faults == []
    assert hd(report.failures).details =~ "missing required keys"
  end

  test "source_absent scans declared roots and never passes a missing path", %{
    repo: repo,
    plan: plan
  } do
    File.mkdir_p!(Path.join(repo, "lib"))
    File.write!(Path.join(repo, "lib/real.ex"), "def cancel(ref), do: stop(ref)\n")

    good = %Prompt{
      num: "01",
      name: "Source",
      target_repos: ["app"],
      verify: %{
        "source_absent" => [
          %{
            "path" => "lib",
            "patterns" => ["def\\s+cancel\\(_ref.*:ok"],
            "extensions" => [".ex"]
          }
        ]
      }
    }

    assert Verifier.verify_prompt(plan, good).pass?

    missing = %{
      good
      | verify: %{"source_absent" => [%{"path" => "missing", "patterns" => ["fake"]}]}
    }

    report = Verifier.verify_prompt(plan, missing)
    refute report.pass?
    assert hd(report.failures).details =~ "missing"
  end
end
