defmodule PromptRunner.PathRewriterTest do
  use ExUnit.Case, async: true

  alias PromptRunner.PathRewriter

  test "rewrites nested paths longest-first throughout provider options" do
    rewrites = %{
      "/source" => "/workspace/repos/root",
      "/source/nested" => "/workspace/repos/nested"
    }

    assert %{
             system_prompt: "edit /workspace/repos/nested/lib and /workspace/repos/root/README",
             provider: %{notes: ["/workspace/repos/root/test"]}
           } ==
             PathRewriter.deep(
               %{
                 system_prompt: "edit /source/nested/lib and /source/README",
                 provider: %{notes: ["/source/test"]}
               },
               rewrites
             )
  end
end
