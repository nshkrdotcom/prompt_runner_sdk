defmodule PromptRunner.MixProject do
  use Mix.Project

  def project do
    [
      app: :prompt_runner_sdk,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:claude_code_sdk, "~> 0.2.2"},
      {:codex_sdk, "~> 0.5.0"},
      {:jason, "~> 1.4"},
      {:mox, "~> 1.1", only: :test},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false}
    ]
  end
end
