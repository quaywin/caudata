# Acknowledge that tailscale-rs is experimental software as required by the library.
System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")

defmodule Caudata.MixProject do
  use Mix.Project

  def project do
    [
      app: :caudata,
      version: current_version(),
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

  defp current_version do
    base = "0.1.15"

    version_from_env() || version_from_git() || base
  end

  defp version_from_env do
    env_version = System.get_env("CAUDATA_VERSION") || System.get_env("VERSION")
    github_ref = System.get_env("GITHUB_REF_NAME")

    cond do
      env_version ->
        env_version |> String.trim() |> String.trim_leading("v")

      github_ref && String.starts_with?(github_ref, "v") ->
        github_ref |> String.trim() |> String.trim_leading("v")

      true ->
        nil
    end
  end

  defp version_from_git do
    if File.exists?(Path.join(__DIR__, ".git")) && System.find_executable("git") do
      case System.cmd("git", ["describe", "--tags", "--long"],
             cd: __DIR__,
             stderr_to_stdout: true
           ) do
        {output, 0} ->
          output
          |> String.trim()
          |> String.split("-")
          |> Enum.reverse()
          |> case do
            [_git_hash, "0" | rest] ->
              rest |> Enum.reverse() |> Enum.join("-") |> String.trim_leading("v")

            [git_hash, count | rest] ->
              tag = rest |> Enum.reverse() |> Enum.join("-") |> String.trim_leading("v")
              hash = String.trim_leading(git_hash, "g")
              "#{tag}+dev.#{count}.#{hash}"

            _ ->
              nil
          end

        _ ->
          nil
      end
    end
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
      {:tailscale, "~> 0.3.3"},
      {:phoenix_live_reload, "~> 1.5", only: :dev},
      {:mox, "~> 1.1", only: :test},
      {:stream_data, "~> 1.1", only: :test},
      {:floki, ">= 0.30.0", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end
end
