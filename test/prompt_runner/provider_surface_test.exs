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

  test "accepts the ASM 0.12 normalized common options on every provider" do
    common = %{
      allow_unknown_model: true,
      completion_only: true,
      output_schema: %{"type" => "object"},
      transport_headless_timeout_ms: 5_000
    }

    for section <- [:claude_opts, :codex_opts, :amp_opts, :cursor_opts, :antigravity_opts] do
      assert :ok = ProviderOptions.validate_section(section, common),
             "expected #{section} to accept the normalized common options"
    end
  end

  test "accepts Claude reasoning effort and the Codex app-server surface" do
    assert :ok =
             ProviderOptions.validate_section(:claude_opts, %{
               model: "sonnet",
               reasoning_effort: :high,
               include_thinking: true
             })

    assert :ok =
             ProviderOptions.validate_section(:codex_opts, %{
               model: "gpt-5.4-mini",
               reasoning_effort: :low,
               app_server: true,
               host_tools: [],
               dynamic_tools: [],
               reviewed_approval: %{}
             })
  end

  test "still rejects an option that no provider schema publishes" do
    assert {:error, {:unsupported_provider_option, :not_a_real_option}} =
             ProviderOptions.validate_section(:claude_opts, %{not_a_real_option: true})
  end
end
