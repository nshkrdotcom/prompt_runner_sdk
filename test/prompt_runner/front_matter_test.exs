defmodule PromptRunner.FrontMatterTest do
  use ExUnit.Case, async: true

  alias PromptRunner.FrontMatter

  test "round-trips nested front matter" do
    attrs = %{
      "name" => "packet",
      "repos" => %{
        "app" => %{"path" => "/tmp/app", "default" => true}
      },
      "targets" => ["app"],
      "recovery" => %{"retry" => %{"max_attempts" => 3}}
    }

    dumped = FrontMatter.dump(attrs, "# Body\n")

    assert {:ok, %{attributes: parsed, body: body}} = FrontMatter.parse(dumped)
    assert parsed["name"] == "packet"
    assert parsed["repos"]["app"]["path"] == "/tmp/app"
    assert parsed["targets"] == ["app"]
    assert parsed["recovery"]["retry"]["max_attempts"] == 3
    assert body =~ "# Body"
  end
end
