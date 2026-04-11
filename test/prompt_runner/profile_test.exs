defmodule PromptRunner.ProfileTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_profile_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  test "init creates config plus codex and simulated default profiles" do
    assert {:ok, paths} = Profile.init()
    assert File.exists?(paths.config_file)
    assert File.exists?(paths.profile_file)
    assert File.exists?(paths.simulated_profile_file)

    assert {:ok, profile} = Profile.load()
    assert profile.name == "codex-default"
    assert profile.options["model"] == "gpt-5.4"

    assert {:ok, simulated} = Profile.load("simulated-default")
    assert simulated.options["provider"] == "simulated"
  end

  test "create and list profiles" do
    assert {:ok, _paths} = Profile.init()

    assert {:ok, profile} =
             Profile.create("claude-safe", %{"provider" => "claude", "model" => "sonnet"})

    assert profile.name == "claude-safe"

    assert {:ok, profiles} = Profile.list()
    assert "claude-safe" in profiles
    assert "codex-default" in profiles
    assert "simulated-default" in profiles
  end
end
