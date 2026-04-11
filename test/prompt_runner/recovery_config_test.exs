defmodule PromptRunner.RecoveryConfigTest do
  use ExUnit.Case, async: true

  alias PromptRunner.RecoveryConfig

  test "normalizes nested recovery configuration with defaults" do
    config =
      RecoveryConfig.normalize(%{
        "recovery" => %{
          "resume_attempts" => "4",
          "retry" => %{"max_attempts" => "5", "base_delay_ms" => "0", "jitter" => "false"},
          "repair" => %{"enabled" => "true", "max_attempts" => "3"}
        }
      })

    assert config["resume_attempts"] == 4
    assert config["retry"]["max_attempts"] == 5
    assert config["retry"]["base_delay_ms"] == 0
    assert config["retry"]["max_delay_ms"] == 30_000
    assert config["retry"]["jitter"] == false
    assert config["repair"]["enabled"] == true
    assert config["repair"]["max_attempts"] == 3
  end

  test "supplies aggressive retry defaults for remote provider claims" do
    config = RecoveryConfig.default()

    assert RecoveryConfig.retry_max_attempts(config, "provider_capacity") == 5
    assert RecoveryConfig.retry_max_attempts(config, "provider_auth_claim") == 3
    assert RecoveryConfig.retry_max_attempts(config, "protocol_error") == 4
  end

  test "applies prompt-local recovery overrides on top of packet defaults" do
    base = RecoveryConfig.default()

    config =
      RecoveryConfig.with_override(base, %{
        "retry" => %{"class_attempts" => %{"provider_runtime_claim" => 1}},
        "repair" => %{"max_attempts" => 4}
      })

    assert RecoveryConfig.retry_max_attempts(config, "provider_runtime_claim") == 1
    assert RecoveryConfig.retry_max_attempts(config, "provider_capacity") == 5
    assert RecoveryConfig.repair_max_attempts(config) == 4
  end
end
