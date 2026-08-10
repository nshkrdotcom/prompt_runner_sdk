defmodule PromptRunner.TemplateTest do
  use ExUnit.Case, async: false

  alias PromptRunner.Profile
  alias PromptRunner.Template
  alias PromptRunner.Test.FSHelpers

  setup do
    config_home = FSHelpers.tmp_dir("prompt_runner_template_home")
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

  test "list returns builtin and home templates" do
    assert {:ok, templates} = Template.list()

    assert Enum.any?(templates, &(&1.name == "default"))
    assert Enum.any?(templates, &(&1.name == "from-adr"))
  end

  test "packet-local templates override home templates of the same name" do
    root = FSHelpers.tmp_dir("prompt_runner_template_packet")
    on_exit(fn -> File.rm_rf!(root) end)

    File.mkdir_p!(Path.join(root, "templates"))

    File.write!(
      Path.join([root, "templates", "default.prompt.md"]),
      """
      ---
      verify:
        files_exist:
          - "packet-local.txt"
      ---
      # {{name}}
      """
    )

    assert {:ok, template} = Template.load("default", packet_root: root)
    assert template.source == :packet
    assert template.attributes["verify"]["files_exist"] == ["packet-local.txt"]
  end

  test "render merges template defaults with generated prompt attrs" do
    assert {:ok, template} = Template.load("from-adr")

    {attrs, body} =
      Template.render(
        %{
          "id" => "01",
          "phase" => 1,
          "name" => "Map contracts",
          "targets" => ["core", "asm"],
          "commit" => "docs: map contracts"
        },
        template
      )

    # The scaffold no longer emits `references`, `required_reading`,
    # `context_files`, or `depends_on`: they are parsed, stored, and never read
    # at runtime, and `packet lint` reports them as inert. Scaffolding a key
    # the runtime ignores teaches the wrong thing on the first prompt someone
    # writes.
    refute Map.has_key?(attrs, "references")
    refute Map.has_key?(attrs, "required_reading")
    refute Map.has_key?(attrs, "context_files")
    refute Map.has_key?(attrs, "depends_on")
    assert attrs["verify"]["files_exist"] == []
    assert attrs["template"] == "from-adr"
    assert body =~ "# Map contracts"
    assert body =~ "## Required Reading"
    assert Template.contains_placeholder_markers?(body)
  end
end
