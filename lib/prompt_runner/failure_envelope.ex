defmodule PromptRunner.FailureEnvelope do
  @moduledoc """
  Prompt Runner's normalized recovery view over provider and runtime failures.
  """

  @default %{
    class: :unknown,
    class_name: "unknown",
    retryable?: true,
    repairable?: true,
    resumeable?: false,
    local_deterministic?: false,
    remote_claim?: true,
    severity: "error",
    phase: nil,
    provider_code: nil,
    suggested_delay_ms: nil,
    suggested_max_attempts: nil,
    message: nil,
    raw: %{}
  }

  @spec from_result(:ok | {:error, term()}) :: map()
  def from_result(:ok), do: success()
  def from_result({:error, reason}), do: from_reason(reason)

  @spec from_reason(term()) :: map()
  def from_reason({:cli_confirmation_missing, details}) do
    fixed_envelope(:cli_confirmation_missing, details,
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      remote_claim?: false,
      local_deterministic?: true
    )
  end

  def from_reason({:cli_confirmation_mismatch, details}) do
    fixed_envelope(:cli_confirmation_mismatch, details,
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      remote_claim?: false,
      local_deterministic?: true
    )
  end

  def from_reason({:start_failed, reason}), do: from_reason(reason)
  def from_reason({:stream_failed, message}), do: from_message_envelope(message)

  def from_reason(reason) do
    provider_error = extract_provider_error(reason)
    recovery = recovery_map(reason, provider_error)
    message = failure_message(reason, provider_error)

    cond do
      map_size(recovery) > 0 ->
        normalize_recovery(recovery, message, provider_error)

      provider_error != %{} ->
        fallback_provider_envelope(provider_error, message)

      true ->
        from_message_envelope(message)
    end
  end

  @spec success() :: map()
  def success do
    %{
      class: :ok,
      class_name: "ok",
      retryable?: false,
      repairable?: false,
      resumeable?: false,
      local_deterministic?: false,
      remote_claim?: false,
      severity: "info",
      phase: nil,
      provider_code: nil,
      suggested_delay_ms: nil,
      suggested_max_attempts: nil,
      message: nil,
      raw: %{}
    }
  end

  @spec class_name(map()) :: String.t()
  def class_name(%{class_name: class_name}) when is_binary(class_name), do: class_name
  def class_name(_envelope), do: "unknown"

  defp fixed_envelope(class, raw, overrides) do
    @default
    |> Map.merge(%{
      class: class,
      class_name: Atom.to_string(class),
      raw: normalize_map(raw),
      message: failure_message(raw, %{})
    })
    |> Map.merge(Map.new(overrides))
  end

  defp recovery_map(reason, provider_error) do
    normalize_map(
      map_get(reason, :recovery) ||
        map_get(provider_error, :recovery) ||
        get_in(provider_error, [:context, :recovery]) ||
        get_in(provider_error, ["context", "recovery"])
    )
  end

  defp normalize_recovery(recovery, message, provider_error) do
    class = normalize_class(map_get(recovery, :class) || "unknown")

    @default
    |> Map.merge(%{
      class: class,
      class_name: Atom.to_string(class),
      retryable?: truthy?(map_get(recovery, :retryable?) || map_get(recovery, :retryable)),
      repairable?: truthy?(map_get(recovery, :repairable?) || map_get(recovery, :repairable)),
      resumeable?: truthy?(map_get(recovery, :resumeable?) || map_get(recovery, :resumeable)),
      local_deterministic?:
        truthy?(
          map_get(recovery, :local_deterministic?) || map_get(recovery, :local_deterministic)
        ),
      remote_claim?:
        truthy?(map_get(recovery, :remote_claim?) || map_get(recovery, :remote_claim)),
      severity: stringify_or_nil(map_get(recovery, :severity)) || "error",
      phase: stringify_or_nil(map_get(recovery, :phase)),
      provider_code:
        stringify_or_nil(map_get(recovery, :provider_code)) || map_get(provider_error, :kind),
      suggested_delay_ms: non_neg_integer(map_get(recovery, :suggested_delay_ms)),
      suggested_max_attempts: non_neg_integer(map_get(recovery, :suggested_max_attempts)),
      message: message,
      raw: recovery
    })
    |> normalize_invariants()
  end

  defp fallback_provider_envelope(provider_error, message) do
    kind = map_get(provider_error, :kind)
    normalized_message = String.downcase(message || "")
    class = fallback_provider_class(kind, normalized_message)
    remote_envelope(class, message, provider_error, fallback_provider_overrides(class))
  end

  defp from_message_envelope(message) do
    normalized = String.downcase(message || "")

    cond do
      capacity_message?(normalized) ->
        remote_envelope(:provider_capacity, message, %{},
          retryable?: true,
          repairable?: true,
          suggested_delay_ms: 2_000
        )

      auth_message?(normalized) ->
        remote_envelope(:provider_auth_claim, message, %{},
          retryable?: true,
          repairable?: true
        )

      config_message?(normalized) ->
        remote_envelope(:provider_config_claim, message, %{},
          retryable?: true,
          repairable?: true
        )

      true ->
        remote_envelope(:provider_runtime_claim, message, %{},
          retryable?: true,
          repairable?: true
        )
    end
  end

  defp remote_envelope(class, message, provider_error, overrides) do
    @default
    |> Map.merge(%{
      class: class,
      class_name: Atom.to_string(class),
      message: message,
      provider_code: stringify_or_nil(map_get(provider_error, :kind)),
      raw: normalize_map(provider_error)
    })
    |> Map.merge(Map.new(overrides))
    |> normalize_invariants()
  end

  defp fallback_provider_class(kind, normalized_message) do
    provider_transport_class(kind, normalized_message) ||
      terminal_or_runtime_class(normalized_message)
  end

  defp protocol_error?(kind, normalized_message) do
    kind in [:protocol_error] or String.contains?(normalized_message, "protocol error")
  end

  defp transport_disconnect?(kind, normalized_message) do
    kind in [:transport_error, :transport_exit] or
      String.contains?(normalized_message, "connection reset") or
      String.contains?(normalized_message, "disconnected")
  end

  defp provider_transport_class(kind, normalized_message) do
    cond do
      protocol_error?(kind, normalized_message) -> :protocol_error
      transport_disconnect?(kind, normalized_message) -> :transport_disconnect
      String.contains?(normalized_message, "timeout") -> :transport_timeout
      capacity_message?(normalized_message) -> :provider_capacity
      auth_message?(normalized_message) -> :provider_auth_claim
      config_message?(normalized_message) -> :provider_config_claim
      true -> nil
    end
  end

  defp terminal_or_runtime_class(normalized_message) do
    cond do
      user_cancel_message?(normalized_message) -> :user_cancelled
      approval_denied_message?(normalized_message) -> :approval_denied
      guardrail_message?(normalized_message) -> :guardrail_blocked
      true -> :provider_runtime_claim
    end
  end

  defp fallback_provider_overrides(:protocol_error),
    do: [retryable?: true, repairable?: true, resumeable?: true]

  defp fallback_provider_overrides(:transport_disconnect),
    do: [retryable?: true, repairable?: true, resumeable?: true]

  defp fallback_provider_overrides(:transport_timeout),
    do: [retryable?: true, repairable?: true, resumeable?: true]

  defp fallback_provider_overrides(:provider_capacity),
    do: [retryable?: true, repairable?: true, resumeable?: false, suggested_delay_ms: 2_000]

  defp fallback_provider_overrides(:provider_auth_claim),
    do: [retryable?: true, repairable?: true]

  defp fallback_provider_overrides(:provider_config_claim),
    do: [retryable?: true, repairable?: true]

  defp fallback_provider_overrides(:user_cancelled),
    do: [retryable?: false, repairable?: false, remote_claim?: false]

  defp fallback_provider_overrides(:approval_denied),
    do: [retryable?: false, repairable?: false, remote_claim?: false]

  defp fallback_provider_overrides(:guardrail_blocked),
    do: [retryable?: false, repairable?: false]

  defp fallback_provider_overrides(:provider_runtime_claim),
    do: [retryable?: true, repairable?: true]

  defp normalize_invariants(envelope) do
    envelope
    |> Map.put_new(:severity, "error")
    |> Map.put_new(:message, nil)
    |> Map.put_new(:raw, %{})
  end

  defp extract_provider_error(reason) do
    case map_get(reason, :provider_error) do
      value when is_map(value) -> value
      _ -> %{}
    end
  end

  defp failure_message(reason, provider_error) do
    map_get(reason, :message) ||
      map_get(provider_error, :message) ||
      if(is_binary(reason), do: reason, else: inspect(reason))
  end

  defp capacity_message?(message) do
    String.contains?(message, "capacity") or String.contains?(message, "rate limit") or
      String.contains?(message, "temporarily unavailable") or
      String.contains?(message, "try again later") or String.contains?(message, "overloaded") or
      String.contains?(message, "busy")
  end

  defp auth_message?(message) do
    String.contains?(message, "api key") or String.contains?(message, "auth") or
      String.contains?(message, "unauthorized") or String.contains?(message, "forbidden") or
      String.contains?(message, "permission")
  end

  defp config_message?(message) do
    String.contains?(message, "unsupported") or String.contains?(message, "invalid") or
      String.contains?(message, "bad request") or String.contains?(message, "unknown model") or
      String.contains?(message, "does not exist") or
      String.contains?(message, "not available")
  end

  defp user_cancel_message?(message) do
    String.contains?(message, "cancelled") or String.contains?(message, "canceled")
  end

  defp approval_denied_message?(message) do
    String.contains?(message, "approval denied") or String.contains?(message, "approval required")
  end

  defp guardrail_message?(message) do
    String.contains?(message, "guardrail") or String.contains?(message, "policy blocked")
  end

  defp normalize_class(value) when is_atom(value), do: value

  defp normalize_class(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.downcase()
    |> String.replace("-", "_")
    |> String.to_atom()
  end

  defp normalize_class(_value), do: :unknown

  defp normalize_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp normalize_map(_value), do: %{}

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp map_get(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp map_get(_map, _key), do: nil

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false

  defp non_neg_integer(value) when is_integer(value) and value >= 0, do: value
  defp non_neg_integer(value) when is_binary(value), do: Integer.parse(value) |> parse_integer()
  defp non_neg_integer(_value), do: nil

  defp parse_integer({value, ""}) when value >= 0, do: value
  defp parse_integer(_value), do: nil

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value), do: to_string(value)
end
