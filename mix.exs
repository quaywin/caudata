defmodule Caudata.MixProject do
  use Mix.Project

  def project do
    [
      app: :caudata,
      version: "0.1.6",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      description:
        "A collaborative, zero-config multi-server log streamer built with Elixir/OTP, Ratatui (TUI), and Phoenix LiveView.",
      package: package(),
      homepage_url: "https://github.com/quaywin/caudata",
      source_url: "https://github.com/quaywin/caudata",
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :ssh],
      mod: {Caudata.Application, []}
    ]
  end

  def releases do
    [
      caudata: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            linux_x86_64: [os: :linux, cpu: :x86_64]
          ],
          extra_steps: [
            patch: [post: [Caudata.BurritoPatch]]
          ]
        ]
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/quaywin/caudata"},
      maintainers: ["quaywin"]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:burrito, "~> 1.0"},
      {:ex_ratatui, "~> 0.10"},
      {:phoenix_ex_ratatui, "~> 0.1"},
      {:plug_cowboy, "~> 2.7"},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20 or ~> 1.0"},
      {:phoenix_pubsub, "~> 2.1"},
      {:bandit, "~> 1.5"},
      {:jason, "~> 1.4"},
      {:nimble_options, "~> 1.1"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.1"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
