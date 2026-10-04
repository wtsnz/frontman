defmodule Frontman.MixProject do
  use Mix.Project

  def project do
    [
      app: :frontman,
      version: "0.1.0",
      elixir: "~> 1.20",
      source_url: "https://github.com/wtsnz/frontman",
      package: [
        files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE),
        licenses: ["MIT"],
        links: %{"GitHub" => "https://github.com/wtsnz/frontman"}
      ],
      description: "Supervised HTTP frontend workers and a streaming Plug proxy",
      deps: [
        {:telemetry, "~> 1.0"},
        {:plug, "~> 1.18"},
        {:muontrap, "~> 2.0"},
        {:finch, "~> 0.23.0"},
        {:jason, "~> 1.4"},
        {:opentelemetry_api, "~> 1.5"},
        {:bandit, "~> 1.0", only: :test}
      ]
    ]
  end

  def application, do: [extra_applications: [:logger]]
end
