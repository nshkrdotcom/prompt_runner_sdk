defmodule PromptRunner.CapabilitiesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PromptRunner.Capabilities
  alias PromptRunner.CLI

  test "the JSON surface is versioned data and requires no checkout probe" do
    output = capture_io(fn -> assert :ok = CLI.main(["capabilities", "--json"]) end)
    decoded = Jason.decode!(output)

    assert decoded["schema"] == "prompt_runner.capabilities/v1"
    assert decoded["version"] == PromptRunner.version()
    assert "selector.upper_bound" in decoded["capabilities"]
    assert "containment.systemd_user" in decoded["capabilities"]
    assert decoded["capabilities"] == Capabilities.list()
  end

  test "version has a machine-readable surface" do
    output = capture_io(fn -> assert :ok = CLI.main(["version", "--json"]) end)
    assert Jason.decode!(output) == %{"version" => PromptRunner.version()}
  end
end
