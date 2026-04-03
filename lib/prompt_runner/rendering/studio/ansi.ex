defmodule PromptRunner.Rendering.Studio.ANSI do
  @moduledoc """
  ANSI terminal utilities for the studio renderer pipeline.
  """

  @red "\e[0;31m"
  @green "\e[0;32m"
  @blue "\e[0;34m"
  @magenta "\e[0;35m"
  @cyan "\e[0;36m"
  @dim "\e[2m"
  @bold "\e[1m"
  @reset "\e[0m"

  def red(text, enabled? \\ true), do: colorize(text, @red, enabled?)
  def green(text, enabled? \\ true), do: colorize(text, @green, enabled?)
  def blue(text, enabled? \\ true), do: colorize(text, @blue, enabled?)
  def cyan(text, enabled? \\ true), do: colorize(text, @cyan, enabled?)
  def magenta(text, enabled? \\ true), do: colorize(text, @magenta, enabled?)
  def dim(text, enabled? \\ true), do: colorize(text, @dim, enabled?)
  def bold(text, enabled? \\ true), do: colorize(text, @bold, enabled?)

  def success, do: "✓"
  def failure, do: "✗"
  def info, do: "●"
  def running, do: "◐"
  def clear_line, do: "\r\e[2K"
  def cursor_up(n), do: "\e[#{n}A"

  def tty? do
    match?({:ok, _}, :io.columns(:stdio))
  end

  defp colorize("", _color, _enabled?), do: ""
  defp colorize(text, _color, false), do: text
  defp colorize(text, color, true), do: color <> text <> @reset
end
