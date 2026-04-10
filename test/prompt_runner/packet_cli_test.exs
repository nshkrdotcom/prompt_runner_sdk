defmodule PromptRunner.PacketCLITest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias PromptRunner.CLI
  alias PromptRunner.Profile
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_cli_home")
    previous = System.get_env("PROMPT_RUNNER_CONFIG_HOME")
    System.put_env("PROMPT_RUNNER_CONFIG_HOME", config_home)
    {:ok, _paths} = Profile.init()

    on_exit(fn ->
      if previous,
        do: System.put_env("PROMPT_RUNNER_CONFIG_HOME", previous),
        else: System.delete_env("PROMPT_RUNNER_CONFIG_HOME")

      File.rm_rf!(config_home)
    end)

    :ok
  end

  test "packet authoring commands create a usable packet" do
    root = FSHelpers.tmp_dir("prompt_runner_cli_packet_root")
    repo = FSHelpers.git_repo!("prompt_runner_cli_repo")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    capture_io(fn ->
      assert :ok = CLI.main(["packet", "new", "demo", "--root", root])

      assert :ok =
               CLI.main([
                 "repo",
                 "add",
                 "app",
                 repo,
                 "--packet",
                 Path.join(root, "demo"),
                 "--default"
               ])

      assert :ok =
               CLI.main([
                 "prompt",
                 "new",
                 "01",
                 "--packet",
                 Path.join(root, "demo"),
                 "--phase",
                 "1",
                 "--name",
                 "Create hello",
                 "--targets",
                 "app",
                 "--commit",
                 "chore: create hello"
               ])

      assert :ok = CLI.main(["checklist", "sync", Path.join(root, "demo")])
    end)

    assert File.exists?(Path.join([root, "demo", "prompt_runner_packet.md"]))
    assert File.exists?(Path.join([root, "demo", "prompts"]))
    assert File.exists?(Path.join([root, "demo", "prompts", "01_create_hello.prompt.md"]))

    assert File.exists?(
             Path.join([root, "demo", "prompts", "01_create_hello.prompt.checklist.md"])
           )
  end
end
