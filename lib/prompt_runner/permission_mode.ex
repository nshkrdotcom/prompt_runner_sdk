defmodule PromptRunner.PermissionMode do
  @moduledoc false

  alias ASM.Permission

  @normalized_modes [:default, :auto, :bypass, :plan]

  @mode_aliases %{
    "default" => :default,
    "auto" => :auto,
    "full_auto" => :auto,
    "accept_edits" => :auto,
    "delegate" => :auto,
    "dont_ask" => :auto,
    "auto_edit" => :auto,
    "bypass" => :bypass,
    "dangerously_skip_permissions" => :bypass,
    "bypass_permissions" => :bypass,
    "yolo" => :bypass,
    "dangerously_allow_all" => :bypass,
    "plan" => :plan
  }

  @spec normalized_modes() :: [atom()]
  def normalized_modes, do: @normalized_modes

  @spec normalize(atom() | String.t() | nil, atom() | nil) :: atom() | String.t() | nil
  def normalize(mode, provider \\ nil)

  def normalize(nil, _provider), do: nil

  def normalize(mode, provider) do
    case Map.get(@mode_aliases, normalize_key(mode)) do
      normalized when normalized in @normalized_modes ->
        normalized

      _other ->
        normalize_with_provider(mode, provider)
    end
  end

  defp normalize_with_provider(mode, nil), do: mode

  defp normalize_with_provider(mode, provider) do
    case Permission.normalize(provider, mode) do
      {:ok, %{normalized: normalized}} -> normalized
      {:error, _reason} -> mode
    end
  end

  defp normalize_key(mode) when is_atom(mode), do: mode |> Atom.to_string() |> normalize_key()

  defp normalize_key(mode) when is_binary(mode) do
    mode
    |> String.trim()
    |> String.replace("-", "_")
    |> Macro.underscore()
    |> String.downcase()
  end

  defp normalize_key(_other), do: nil
end
