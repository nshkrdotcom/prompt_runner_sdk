defmodule PromptRunner.UI do
  @moduledoc false

  @red "\e[0;31m"
  @green "\e[0;32m"
  @yellow "\e[1;33m"
  @blue "\e[0;34m"
  @cyan "\e[0;36m"
  @magenta "\e[0;35m"
  @dim "\e[2m"
  @bold "\e[1m"
  @nc "\e[0m"

  def red(text), do: colorize(text, @red)
  def green(text), do: colorize(text, @green)
  def yellow(text), do: colorize(text, @yellow)
  def blue(text), do: colorize(text, @blue)
  def cyan(text), do: colorize(text, @cyan)
  def magenta(text), do: colorize(text, @magenta)
  def dim(text), do: colorize(text, @dim)
  def bold(text), do: colorize(text, @bold)

  def nc, do: @nc

  def colorize(text, color) when is_binary(text) do
    if text == "" do
      ""
    else
      color <> text <> @nc
    end
  end
end
