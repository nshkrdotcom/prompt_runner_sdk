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
    build_from_input(input, interface, opts)
  end

  defp build_from_input(input, interface, opts) when is_list(input) do
    if Enum.all?(input, &match?(%Prompt{}, &1)) do
      {:ok,
       %__MODULE__{
         input: input,
         input_type: :prompt_list,
         source: ListSource,
         interface: interface,
         opts: opts
       }}
    else
      {:error, {:unsupported_input, input}}
    end
  end

  defp build_from_input(input, interface, opts) when is_binary(input) do
    cond do
      File.dir?(input) ->
        build_directory_spec(input, interface, opts)

      File.regular?(input) and String.ends_with?(input, ".exs") ->
        {:ok,
         %__MODULE__{
           input: input,
           input_type: :legacy_config,
           source: LegacyConfigSource,
           interface: :legacy,
           opts: opts
         }}

      true ->
        {:ok,
         %__MODULE__{
           input: input,
           input_type: :single_prompt,
           source: SinglePromptSource,
           interface: interface,
           opts: opts
         }}
    end
  end

  defp build_from_input(input, _interface, _opts), do: {:error, {:unsupported_input, input}}

  defp build_directory_spec(input, interface, opts) do
    {source, input_type, resolved_interface} =
      if legacy_directory?(input) do
        {LegacyConfigSource, :legacy_config, :legacy}
      else
        {DirectorySource, :directory, interface}
      end

    {:ok,
     %__MODULE__{
       input: input,
       input_type: input_type,
       source: source,
       interface: resolved_interface,
       opts: opts
     }}
  end

  defp legacy_directory?(dir) do
    File.exists?(Path.join(dir, "runner_config.exs")) and
      File.exists?(Path.join(dir, "prompts.txt"))
  end
end
