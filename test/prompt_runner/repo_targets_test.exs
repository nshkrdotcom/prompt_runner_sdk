defmodule PromptRunner.RepoTargetsTest do
  use ExUnit.Case, async: true

  alias PromptRunner.RepoTargets

  test "expands group references" do
    {resolved, errors} =
      RepoTargets.expand(["@pipeline"], %{"pipeline" => ["command", "flowstone"]})

    assert resolved == ["command", "flowstone"]
    assert errors == []
  end

  test "expands mixed groups and repos and de-duplicates" do
    {resolved, errors} =
      RepoTargets.expand(["@pipeline", "command"], %{"pipeline" => ["command", "flowstone"]})

    assert resolved == ["command", "flowstone"]
    assert errors == []
  end

  test "expands nested groups" do
    repo_groups = %{"portfolio" => ["@pipeline", "portfolio_core"], "pipeline" => ["command"]}

    {resolved, errors} = RepoTargets.expand(["@portfolio"], repo_groups)
    assert resolved == ["command", "portfolio_core"]
    assert errors == []
  end

  test "reports unknown group errors while still expanding other targets" do
    {resolved, errors} =
      RepoTargets.expand(["@missing", "command"], %{"pipeline" => ["command", "flowstone"]})

    assert resolved == ["command"]
    assert {:unknown_group, "missing"} in errors
  end

  test "detects cycles in group definitions" do
    {resolved, errors} = RepoTargets.expand(["@a"], %{"a" => ["@b"], "b" => ["@a"]})
    assert resolved == []
    assert {:cycle, ["a", "b", "a"]} in errors
  end

  test "expand! raises on unknown groups" do
    assert_raise RuntimeError, "Unknown repo group: @missing", fn ->
      RepoTargets.expand!(["@missing"], %{})
    end
  end

  test "reports invalid group values" do
    {resolved, errors} = RepoTargets.expand(["@bad"], %{"bad" => "oops"})
    assert resolved == []
    assert {:invalid_group_value, "bad", "oops"} in errors
  end
end
