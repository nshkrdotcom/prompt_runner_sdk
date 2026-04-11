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

  test "packet new accepts repeated repo declarations and prompt new accepts templates" do
    root = FSHelpers.tmp_dir("prompt_runner_cli_packet_root")
    repo = FSHelpers.git_repo!("prompt_runner_cli_repo")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.main([
                   "packet",
                   "new",
                   "demo",
                   "--root",
                   root,
                   "--repo",
                   "app=#{repo}",
                   "--default-repo",
                   "app",
                   "--prompt-template",
                   "from-adr"
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
                   "Map contracts",
                   "--targets",
                   "app",
                   "--commit",
                   "docs: map contracts"
                 ])

        assert :ok = CLI.main(["template", "list", Path.join(root, "demo")])
      end)

    packet_root = Path.join(root, "demo")
    prompt_path = Path.join([packet_root, "prompts", "01_map_contracts.prompt.md"])

    assert {:ok, packet} = PromptRunner.Packet.load(packet_root)
    assert packet.options["prompt_template"] == "from-adr"
    assert [%{name: "app", default: true, path: ^repo}] = packet.repos
    assert File.read!(prompt_path) =~ "## Required Reading"
    assert File.read!(prompt_path) =~ "template: \"from-adr\""
    assert output =~ "from-adr"
  end

  test "checklist sync warns for prompts without verifier items" do
    root = FSHelpers.tmp_dir("prompt_runner_cli_packet_root")
    repo = FSHelpers.git_repo!("prompt_runner_cli_repo")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    capture_io(fn ->
      assert :ok = CLI.main(["packet", "new", "demo", "--root", root, "--repo", "app=#{repo}"])

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
                 "Draft prompt",
                 "--targets",
                 "app"
               ])
    end)

    output =
      capture_io(fn ->
        assert :ok = CLI.main(["checklist", "sync", Path.join(root, "demo")])
      end)

    assert output =~ "WARNING: prompt 01"
    assert output =~ "has no verification items yet"
  end

  test "packet new accepts runtime defaults from CLI flags" do
    root = FSHelpers.tmp_dir("prompt_runner_cli_packet_root")
    on_exit(fn -> File.rm_rf!(root) end)

    capture_io(fn ->
      assert :ok =
               CLI.main([
                 "packet",
                 "new",
                 "demo",
                 "--root",
                 root,
                 "--profile",
                 "simulated-default",
                 "--provider",
                 "simulated",
                 "--model",
                 "simulated-demo",
                 "--permission",
                 "bypass",
                 "--resume-attempts",
                 "3",
                 "--retry-attempts",
                 "3",
                 "--repair-attempts",
                 "4",
                 "--auto-repair"
               ])
    end)

    assert {:ok, packet} = PromptRunner.Packet.load(Path.join(root, "demo"))
    assert packet.profile_name == "simulated-default"
    assert packet.options["provider"] == "simulated"
    assert packet.options["model"] == "simulated-demo"
    assert packet.options["recovery"]["resume_attempts"] == 3
    assert packet.options["recovery"]["retry"]["max_attempts"] == 3
    assert packet.options["recovery"]["repair"]["enabled"] == true
    assert packet.options["recovery"]["repair"]["max_attempts"] == 4
  end
end
