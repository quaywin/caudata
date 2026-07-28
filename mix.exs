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

  defp host_target do
    case :os.type() do
      {:unix, :darwin} ->
        arch = :erlang.system_info(:system_architecture) |> to_string()

        if String.contains?(arch, "aarch64") or String.contains?(arch, "arm64") do
          :macos_aarch64
        else
          :macos_x86_64
        end

      {:unix, :linux} ->
        arch = :erlang.system_info(:system_architecture) |> to_string()

        if String.contains?(arch, "x86_64") or String.contains?(arch, "amd64") do
          :linux_x86_64
        else
          nil
        end

      _ ->
        nil
    end
  end

  def releases do
    local_erts = to_string(:code.root_dir())
    host = host_target()

    targets = [
      macos_aarch64: [os: :darwin, cpu: :aarch64],
      linux_x86_64: [os: :linux, cpu: :x86_64]
    ]

    targets =
      Enum.map(targets, fn {name, opts} ->
        if name == host do
          {name, Keyword.put(opts, :custom_erts, local_erts)}
        else
          {name, opts}
        end
      end)

    targets =
      case System.get_env("BURRITO_TARGET") do
        "macos_aarch64" -> Keyword.take(targets, [:macos_aarch64])
        "linux_x86_64" -> Keyword.take(targets, [:linux_x86_64])
        _ -> targets
      end

    [
      caudata: [
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: targets,
          plugin: "rel/burrito_plugin.zig",
          extra_steps: [
            patch: [post: [Caudata.BurritoPatch]]
          ]
        ]
      ]
    ]
  end

  defp current_version do
    base = "0.1.59"

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
      {:ex_ratatui,
       git: "https://github.com/quaywin/ex_ratatui.git", branch: "main", override: true},
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
