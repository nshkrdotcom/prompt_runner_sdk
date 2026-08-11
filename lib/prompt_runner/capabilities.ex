defmodule PromptRunner.Capabilities do
  @moduledoc """
  Versioned capabilities exposed without compiling or inspecting a checkout.

  The values are baked into the installed escript. Consumers use this data
  surface instead of invoking Mix help tasks or grepping source files.
  """

  @schema "prompt_runner.capabilities/v1"
  @capabilities_file Path.expand("../../priv/capabilities", __DIR__)
  @external_resource @capabilities_file
  @capabilities @capabilities_file
                |> File.read!()
                |> String.split("\n", trim: true)
                |> Enum.reject(&String.starts_with?(&1, "#"))

  @spec schema() :: String.t()
  def schema, do: @schema

  @spec list() :: [String.t()]
  def list, do: @capabilities

  @spec document() :: map()
  def document do
    %{schema: @schema, version: PromptRunner.version(), capabilities: @capabilities}
  end
end
