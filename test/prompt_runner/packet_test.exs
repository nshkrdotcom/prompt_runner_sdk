defmodule PromptRunner.PacketTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Config
  alias PromptRunner.Packet
  alias PromptRunner.Packets
  alias PromptRunner.Profile
  alias PromptRunner.Source.PacketSource
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_packet_home")
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

  test "new packet creates a manifest and loads packet metadata" do
    root = FSHelpers.tmp_dir("prompt_runner_packet_root")
    on_exit(fn -> File.rm_rf!(root) end)

    assert {:ok, packet} = Packet.new("sample-packet", root: root)
    assert File.exists?(packet.manifest_path)
    assert packet.name == "sample-packet"
    assert packet.profile_name == "codex-default"
  end

  test "add_repo updates the manifest and packet source loads prompts" do
    root = FSHelpers.tmp_dir("prompt_runner_packet_root")
    repo = FSHelpers.git_repo!("prompt_runner_packet_repo")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(repo) end)

    assert {:ok, packet} = Packet.new("sample-packet", root: root)

    File.write!(
      packet.manifest_path,
      """
      ---
      name: "sample-packet"
      profile: "codex-default"
      provider: "codex"
      model: "gpt-5.4"
      codex_thread_opts:
        additional_directories:
          - "#{repo}"
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Sample Packet
      """
    )

    assert {:ok, packet} = Packet.load(packet.root)

    assert {:ok, prompt_path} =
             Packets.create_prompt(packet.root, %{
               "id" => "01",
               "phase" => 1,
               "name" => "Create hello",
               "targets" => ["app"],
               "commit" => "chore: create hello"
             })

    File.write!(
      prompt_path,
      """
      ---
      id: "01"
      phase: 1
      name: "Create hello"
      targets:
        - "app"
      commit: "chore: create hello"
      codex_thread_opts:
        additional_directories:
          - "#{repo}"
      verify:
        files_exist:
          - "hello.txt"
      ---
      # Create hello

      ## Mission

      Create `hello.txt`.
      """
    )

    assert {:ok, result} = PacketSource.load(packet.root, [])
    assert length(result.prompts) == 1
    assert hd(result.prompts).verify["files_exist"] == ["hello.txt"]
    assert result.target_repos == [%{default: true, name: "app", path: repo}]
    assert result.metadata[:options]["codex_thread_opts"]["additional_directories"] == [repo]

    assert result.metadata[:options]["prompt_overrides"]["01"]["codex_thread_opts"][
             "additional_directories"
           ] == [repo]
  end

  test "packet planning applies packet options and prompt-local overrides" do
    root = FSHelpers.tmp_dir("prompt_runner_packet_root")
    repo = FSHelpers.git_repo!("prompt_runner_packet_repo")
    extra = FSHelpers.git_repo!("prompt_runner_packet_extra")
    on_exit(fn -> File.rm_rf!(root) end)
    on_exit(fn -> File.rm_rf!(repo) end)
    on_exit(fn -> File.rm_rf!(extra) end)

    assert {:ok, packet} = Packet.new("sample-packet", root: root)

    File.write!(
      packet.manifest_path,
      """
      ---
      name: "sample-packet"
      profile: "codex-default"
      provider: "codex"
      model: "gpt-5.4"
      reasoning_effort: "xhigh"
      codex_thread_opts:
        additional_directories:
          - "#{extra}"
      repos:
        app:
          path: "#{repo}"
          default: true
      ---
      # Sample Packet
      """
    )

    File.write!(
      Path.join([packet.root, "prompts", "01_create_hello.prompt.md"]),
      """
      ---
      id: "01"
      phase: 1
      name: "Create hello"
      targets:
        - "app"
      commit: "chore: create hello"
      provider: "codex"
      model: "gpt-5.4"
      verify:
        files_exist:
          - "hello.txt"
      ---
      # Create hello
      """
    )

    assert {:ok, plan} = PromptRunner.plan(packet.root, interface: :cli)
    assert plan.config.llm_sdk == :codex
    assert plan.config.model == "gpt-5.4"
    assert plan.options[:codex_thread_opts]["additional_directories"] == [extra]

    llm = Config.llm_for_prompt(plan.config, hd(plan.prompts))

    assert llm.sdk == :codex
    assert llm.model == "gpt-5.4"
    assert llm.codex_thread_opts.additional_directories == [extra]
  end
end
