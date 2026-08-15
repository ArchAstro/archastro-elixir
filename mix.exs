defmodule ArchAstro.SDK.MixProject do
  use Mix.Project

  def project do
    [
      app: :archastro,
      version: "0.3.1",
      elixir: ">= 1.15.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "Elixir SDK for the ArchAstro Platform API",
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/ArchAstro/archastro-elixir"}
      ],
      docs: [main: "readme", extras: ["README.md"]],
      test_coverage: [tool: ExCoveralls],
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")],
      dialyzer: [plt_add_apps: [:mix]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  def cli do
    [preferred_envs: [dialyzer: :dev]]
  end

  defp deps do
    [
      {:req, ">= 0.5.0 and < 0.8.0"},
      {:jason, "~> 1.4"},
      {:slipstream, "~> 1.2"},
      {:telemetry, "~> 1.2"},
      {:plug, "~> 1.16", only: :test},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false},
      {:excoveralls, "~> 0.18", only: :test}
    ]
  end
end
