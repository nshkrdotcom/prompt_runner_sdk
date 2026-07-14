defmodule PromptRunner.ProviderSurfaceTest do
  use ExUnit.Case, async: true

  alias PromptRunner.LLMFacade
  alias PromptRunner.ProviderOptions

  test "normalizes the exact public ASM provider set and supported aliases" do
    assert LLMFacade.normalize_provider("claude_agent_sdk") == :claude
    assert LLMFacade.normalize_provider("codex_sdk") == :codex
    assert LLMFacade.normalize_provider("amp_sdk") == :amp
    assert LLMFacade.normalize_provider("cursor_agent") == :cursor
    assert LLMFacade.normalize_provider("antigravity_cli_sdk") == :antigravity

    assert {:error, {:invalid_llm_sdk, "gemini"}} = LLMFacade.normalize_provider("gemini")

    assert {:error, {:invalid_llm_sdk, "gemini_cli_sdk"}} =
             LLMFacade.normalize_provider("gemini_cli_sdk")
  end

  test "publishes provider-specific Cursor and Antigravity option sections" do
    assert ProviderOptions.section_provider(:cursor_opts) == :cursor
    assert ProviderOptions.section_provider(:antigravity_opts) == :antigravity
    assert ProviderOptions.section_provider(:gemini_opts) == nil

    assert :ok =
             ProviderOptions.validate_section(:cursor_opts, %{
               model: "composer",
               mode: :plan,
               sandbox: true,
               approve_mcps: true,
               worktree: true,
               worktree_base: "main",
               skip_worktree_setup: true,
               plugin_dirs: ["/plugins"],
               headers: [{"X-Demo", "true"}]
             })

    assert :ok =
             ProviderOptions.validate_section(:antigravity_opts, %{
               model: "default",
               sandbox: true,
               dangerously_skip_permissions: true,
               conversation: "conversation-1",
               continue: true,
               add_dirs: ["/workspace"],
               print_timeout: "30s",
               log_file: "/tmp/agy.log"
             })
  end
end
