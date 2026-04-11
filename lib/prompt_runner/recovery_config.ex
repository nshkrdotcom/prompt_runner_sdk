defmodule PromptRunner.RecoveryConfig do
  @moduledoc """
  Normalization and defaults for Prompt Runner recovery policy.
  """

  @default_retry_class_attempts %{
    "provider_capacity" => 5,
    "provider_rate_limit" => 5,
    "provider_auth_claim" => 3,
    "provider_config_claim" => 3,
    "provider_runtime_claim" => 3,
    "transport_disconnect" => 4,
    "transport_timeout" => 4,
    "protocol_error" => 4,
    "unknown" => 3
  }

  @default %{
    "resume_attempts" => 2,
    "retry" => %{
      "max_attempts" => 3,
      "base_delay_ms" => 1_000,
      "max_delay_ms" => 30_000,
      "jitter" => true,
      "class_attempts" => @default_retry_class_attempts
    },
    "repair" => %{
      "enabled" => true,
      "max_attempts" => 2,
      "trigger_on_nominal_success_with_failed_verifier" => true,
      "trigger_on_provider_failure_with_workspace_changes" => true,
      "trigger_on_retry_exhaustion_with_workspace_changes" => true
    }
  }

  @type t :: map()

  @spec default() :: t()
  def default, do: deep_copy(@default)

  @spec normalize(map() | nil) :: t()
  def normalize(opts) when is_map(opts) do
    opts
    |> stringify_keys()
    |> Map.get("recovery", %{})
    |> stringify_keys()
    |> then(&deep_merge(default(), &1))
    |> normalize_numbers()
    |> normalize_booleans()
  end

  def normalize(_opts), do: default()

  @spec from_options(map()) :: t()
  def from_options(options) when is_map(options), do: normalize(options)

  @spec with_override(t(), map() | nil) :: t()
  def with_override(base, override) when is_map(base) and is_map(override) do
    %{"recovery" => deep_merge(base, stringify_keys(override))} |> normalize()
  end

  def with_override(base, _override) when is_map(base), do: base

  @spec resume_attempts(t()) :: non_neg_integer()
  def resume_attempts(config) when is_map(config),
    do: non_neg_integer(Map.get(config, "resume_attempts"), 2)

  @spec retry_max_attempts(t(), String.t()) :: non_neg_integer()
  def retry_max_attempts(config, class_name) when is_map(config) and is_binary(class_name) do
    retry = Map.get(config, "retry", %{})
    class_attempts = Map.get(retry, "class_attempts", %{})

    class_attempts
    |> Map.get(class_name, Map.get(retry, "max_attempts", 3))
    |> non_neg_integer(3)
  end

  @spec retry_base_delay_ms(t()) :: non_neg_integer()
  def retry_base_delay_ms(config) when is_map(config) do
    config |> Map.get("retry", %{}) |> Map.get("base_delay_ms") |> non_neg_integer(1_000)
  end

  @spec retry_max_delay_ms(t()) :: non_neg_integer()
  def retry_max_delay_ms(config) when is_map(config) do
    config |> Map.get("retry", %{}) |> Map.get("max_delay_ms") |> non_neg_integer(30_000)
  end

  @spec retry_jitter?(t()) :: boolean()
  def retry_jitter?(config) when is_map(config) do
    config |> Map.get("retry", %{}) |> Map.get("jitter", true) |> truthy?()
  end

  @spec repair_enabled?(t()) :: boolean()
  def repair_enabled?(config) when is_map(config) do
    config |> Map.get("repair", %{}) |> Map.get("enabled", true) |> truthy?()
  end

  @spec repair_max_attempts(t()) :: non_neg_integer()
  def repair_max_attempts(config) when is_map(config) do
    config |> Map.get("repair", %{}) |> Map.get("max_attempts") |> non_neg_integer(2)
  end

  @spec repair_trigger?(t(), String.t()) :: boolean()
  def repair_trigger?(config, key) when is_map(config) and is_binary(key) do
    config
    |> Map.get("repair", %{})
    |> Map.get(key, false)
    |> truthy?()
  end

  defp normalize_numbers(config) do
    config
    |> put_path(["resume_attempts"], non_neg_integer(get_path(config, ["resume_attempts"]), 2))
    |> put_path(
      ["retry", "max_attempts"],
      non_neg_integer(get_path(config, ["retry", "max_attempts"]), 3)
    )
    |> put_path(
      ["retry", "base_delay_ms"],
      non_neg_integer(get_path(config, ["retry", "base_delay_ms"]), 1_000)
    )
    |> put_path(
      ["retry", "max_delay_ms"],
      non_neg_integer(get_path(config, ["retry", "max_delay_ms"]), 30_000)
    )
    |> put_path(
      ["repair", "max_attempts"],
      non_neg_integer(get_path(config, ["repair", "max_attempts"]), 2)
    )
    |> update_path(["retry", "class_attempts"], fn class_attempts ->
      class_attempts
      |> stringify_keys()
      |> Enum.into(%{}, fn {key, value} -> {key, non_neg_integer(value, 3)} end)
    end)
  end

  defp normalize_booleans(config) do
    config
    |> put_path(["retry", "jitter"], truthy?(get_path(config, ["retry", "jitter"])))
    |> put_path(["repair", "enabled"], truthy?(get_path(config, ["repair", "enabled"])))
    |> put_path(
      ["repair", "trigger_on_nominal_success_with_failed_verifier"],
      truthy?(get_path(config, ["repair", "trigger_on_nominal_success_with_failed_verifier"]))
    )
    |> put_path(
      ["repair", "trigger_on_provider_failure_with_workspace_changes"],
      truthy?(get_path(config, ["repair", "trigger_on_provider_failure_with_workspace_changes"]))
    )
    |> put_path(
      ["repair", "trigger_on_retry_exhaustion_with_workspace_changes"],
      truthy?(get_path(config, ["repair", "trigger_on_retry_exhaustion_with_workspace_changes"]))
    )
  end

  defp get_path(map, [key]) when is_map(map), do: Map.get(map, key)

  defp get_path(map, [key | rest]) when is_map(map) do
    case Map.get(map, key) do
      value when is_map(value) -> get_path(value, rest)
      _ -> nil
    end
  end

  defp get_path(_map, _path), do: nil

  defp put_path(map, [key], value) when is_map(map), do: Map.put(map, key, value)

  defp put_path(map, [key | rest], value) when is_map(map) do
    nested =
      map
      |> Map.get(key, %{})
      |> stringify_keys()
      |> put_path(rest, value)

    Map.put(map, key, nested)
  end

  defp update_path(map, [key], fun) when is_map(map), do: Map.update!(map, key, fun)

  defp update_path(map, [key | rest], fun) when is_map(map) do
    nested =
      map
      |> Map.get(key, %{})
      |> stringify_keys()
      |> update_path(rest, fun)

    Map.put(map, key, nested)
  end

  defp stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
  end

  defp stringify_keys(_other), do: %{}

  defp normalize_value(value) when is_map(value), do: stringify_keys(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn _key, l, r ->
      if is_map(l) and is_map(r), do: deep_merge(l, r), else: r
    end)
  end

  defp deep_merge(_left, right), do: right

  defp deep_copy(value) when is_map(value) do
    Map.new(value, fn {key, inner} -> {key, deep_copy(inner)} end)
  end

  defp deep_copy(value) when is_list(value), do: Enum.map(value, &deep_copy/1)
  defp deep_copy(value), do: value

  defp non_neg_integer(value, _default) when is_integer(value) and value >= 0, do: value

  defp non_neg_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} when parsed >= 0 -> parsed
      _ -> default
    end
  end

  defp non_neg_integer(_value, default), do: default

  defp truthy?(value) when value in [true, "true", "TRUE", "1", 1], do: true
  defp truthy?(_value), do: false
end
