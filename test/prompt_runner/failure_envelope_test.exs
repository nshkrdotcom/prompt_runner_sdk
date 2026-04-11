defmodule PromptRunner.FailureEnvelopeTest do
  use ExUnit.Case, async: true

  alias PromptRunner.FailureEnvelope

  test "normalizes structured provider recovery metadata" do
    envelope =
      FailureEnvelope.from_reason(%{
        provider_error: %{
          kind: :runtime_error,
          message: "auth handshake failed",
          recovery: %{
            "class" => "provider_auth_claim",
            "retryable?" => true,
            "repairable?" => true,
            "resumeable?" => false,
            "remote_claim?" => true,
            "local_deterministic?" => false,
            "severity" => "error",
            "suggested_delay_ms" => 1500
          }
        }
      })

    assert envelope.class == :provider_auth_claim
    assert envelope.retryable? == true
    assert envelope.repairable? == true
    assert envelope.resumeable? == false
    assert envelope.remote_claim? == true
    assert envelope.local_deterministic? == false
    assert envelope.suggested_delay_ms == 1500
  end

  test "treats temporary model unavailability as a retryable remote capacity/runtime claim" do
    envelope =
      FailureEnvelope.from_reason(%{
        provider_error: %{
          kind: :runtime_error,
          message: "Selected model is temporarily unavailable."
        }
      })

    assert envelope.class == :provider_capacity
    assert envelope.retryable? == true
    assert envelope.remote_claim? == true
  end

  test "marks CLI confirmation mismatches as local deterministic failures" do
    envelope =
      FailureEnvelope.from_reason(
        {:cli_confirmation_mismatch,
         %{configured_model: "gpt-5.4", confirmed_model: "gpt-5.3-codex"}}
      )

    assert envelope.class == :cli_confirmation_mismatch
    assert envelope.retryable? == false
    assert envelope.local_deterministic? == true
  end

  test "classifies rate limit messages as retryable provider rate limits" do
    envelope =
      FailureEnvelope.from_reason(%{
        provider_error: %{
          kind: :provider_rate_limit,
          message: "Rate limit exceeded. Please slow down."
        }
      })

    assert envelope.class == :provider_rate_limit
    assert envelope.retryable? == true
    assert envelope.remote_claim? == true
  end

  test "classifies approval denied as terminal" do
    envelope =
      FailureEnvelope.from_reason(%{
        provider_error: %{
          kind: :approval_denied,
          message: "Tool approval denied by operator."
        }
      })

    assert envelope.class == :approval_denied
    assert envelope.retryable? == false
    assert envelope.repairable? == false
  end

  test "classifies guardrail blocks as terminal" do
    envelope =
      FailureEnvelope.from_reason(%{
        provider_error: %{
          kind: :guardrail_blocked,
          message: "Tool blocked by policy."
        }
      })

    assert envelope.class == :guardrail_blocked
    assert envelope.retryable? == false
    assert envelope.repairable? == false
  end
end
