defmodule Accentone.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/eiger-code/ex-accentone"

  def project do
    [
      app: :accentone,
      name: "Accentone",
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_coverage: [summary: [threshold: 90]],
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:jason, "~> 1.4"},
      {:req_llm, "~> 1.28"},
      {:telemetry, "~> 1.0"},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false, warn_if_outdated: true},
      {:plug, "~> 1.0", only: :test},
      {:bandit, "~> 1.12", only: :test}
    ]
  end

  defp description do
    "Extract a color palette from an image with an LLM vision model — in the " <>
      "cloud or on your own machine."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md assets)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: [{"README.md", [title: "Accentone"]}, "CHANGELOG.md"],
      logo: "assets/logo.svg",
      assets: %{"assets" => "assets"}
    ]
  end
end
