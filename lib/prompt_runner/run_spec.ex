defmodule PromptRunner.RunSpec do
  @moduledoc """
  Normalized description of a requested prompt run before planning.
  """

  alias PromptRunner.Prompt
  alias PromptRunner.Source.DirectorySource
  alias PromptRunner.Source.LegacyConfigSource
  alias PromptRunner.Source.ListSource
  alias PromptRunner.Source.SinglePromptSource

  @type input_type :: :directory | :legacy_config | :prompt_list | :single_prompt

  @type t :: %__MODULE__{
          input: term(),
          input_type: input_type(),
          source: module(),
          interface: :api | :cli | :legacy,
          opts: keyword()
        }

  defstruct [:input, :input_type, :source, :interface, opts: []]

  @spec build(term(), keyword()) :: {:ok, t()} | {:error, term()}
  def build(input, opts \\ []) do
    interface = opts[:interface] || :api

    cond do
      is_list(input) and Enum.all?(input, &match?(%Prompt{}, &1)) ->
        {:ok,
         %__MODULE__{
           input: input,
           input_type: :prompt_list,
           source: ListSource,
           interface: interface,
           opts: opts
         }}

      is_binary(input) and File.dir?(input) ->
        source =
          if legacy_directory?(input) do
            LegacyConfigSource
          else
            DirectorySource
          end

        type = if source == LegacyConfigSource, do: :legacy_config, else: :directory
        iface = if source == LegacyConfigSource, do: :legacy, else: interface

        {:ok,
         %__MODULE__{input: input, input_type: type, source: source, interface: iface, opts: opts}}

      is_binary(input) and File.regular?(input) and String.ends_with?(input, ".exs") ->
        {:ok,
         %__MODULE__{
           input: input,
           input_type: :legacy_config,
           source: LegacyConfigSource,
           interface: :legacy,
           opts: opts
         }}

      is_binary(input) ->
        {:ok,
         %__MODULE__{
           input: input,
           input_type: :single_prompt,
           source: SinglePromptSource,
           interface: interface,
           opts: opts
         }}

      true ->
        {:error, {:unsupported_input, input}}
    end
  end

  defp legacy_directory?(dir) do
    File.exists?(Path.join(dir, "runner_config.exs")) and
      File.exists?(Path.join(dir, "prompts.txt"))
  end
end
