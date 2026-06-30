defmodule Caudata.CLI do
  @moduledoc """
  Command Line Interface helper for version checking, updates, and help messages.
  """

  # Fetch from API or environment if needed
  @owner "quaywin"
  @repo "caudata"

  @doc """
  Handles CLI arguments. Returns `:continue` if execution should proceed, or exits.
  """
  def handle_args(args) do
    case args do
      [] ->
        :continue

      ["--version"] ->
        print_version()
        System.halt(0)

      ["-v"] ->
        print_version()
        System.halt(0)

      ["--help"] ->
        print_help()
        System.halt(0)

      ["-h"] ->
        print_help()
        System.halt(0)

      ["upgrade"] ->
        run_upgrade()
        System.halt(0)

      ["web" | rest] ->
        case OptionParser.parse(rest,
               aliases: [p: :port, t: :tailscale, k: :authkey],
               strict: [
                 port: :integer,
                 tailscale: :boolean,
                 authkey: :string,
                 tailscale_port: :integer
               ]
             ) do
          {opts, [], []} ->
            port =
              opts[:port] ||
                case System.get_env("PORT") do
                  nil ->
                    4000

                  val ->
                    case Integer.parse(val) do
                      {num, ""} -> num
                      _ -> 4000
                    end
                end

            if opts[:tailscale] && opts[:authkey] do
              System.put_env("TAILSCALE_AUTHKEY", opts[:authkey])
              ts_port = opts[:tailscale_port] || 80
              System.put_env("TAILSCALE_WEB_PORT", to_string(ts_port))
            end

            {:web, port}

          _ ->
            IO.puts(
              :stderr,
              "Invalid web options. Usage: caudata web [--port PORT] [--tailscale --authkey KEY]"
            )

            System.halt(1)
        end

      _ ->
        IO.puts(:stderr, "Unrecognized arguments: #{Enum.join(args, " ")}")
        print_help()
        System.halt(1)
    end
  end

  def print_version do
    version = get_current_version()
    IO.puts("Caudata v#{version}")
  end

  def print_help do
    IO.puts("""
    Caudata - A collaborative, zero-config multi-server log streamer.

    Usage:
      caudata [options]
      caudata web [web_options]
      caudata upgrade

    Options:
      -h, --help      Show this help message
      -v, --version   Show version information

    Web Options:
      -p, --port      Port to run the web server on (default: 4000)

    Commands:
      web             Run the web UI server
      upgrade         Check for and install the latest version of Caudata
    """)
  end

  def get_current_version do
    case Application.spec(:caudata, :vsn) do
      # Fallback if not loaded
      nil -> "0.1.14"
      vsn -> to_string(vsn)
    end
  end

  @doc """
  Checks if there is a newer version available on GitHub.
  Returns `{:update_available, tag_name}` or `:no_update` or `{:error, reason}`.
  """
  def check_for_update do
    case get_latest_tag() do
      {:ok, latest_tag} ->
        current = get_current_version() |> String.trim_leading("v")
        latest = latest_tag |> String.trim_leading("v")

        # Ignore if we are running in dev/timestamp mode and not running inside Burrito
        if String.contains?(current, "+dev") and
             match?({:error, :not_in_burrito}, get_binary_path()) do
          :no_update
        else
          case compare_versions(current, latest) do
            :lt -> {:update_available, latest_tag}
            _ -> :no_update
          end
        end

      error ->
        error
    end
  end

  def run_upgrade do
    IO.puts("Checking for updates...")

    case check_for_update() do
      {:update_available, latest_tag} ->
        IO.puts("New version #{latest_tag} is available!")

        case get_binary_path() do
          {:ok, bin_path} ->
            case get_target() do
              {:ok, target} ->
                download_url =
                  "https://github.com/#{@owner}/#{@repo}/releases/download/#{latest_tag}/caudata_#{target}"

                IO.puts("Downloading update for #{target}...")
                IO.puts("From: #{download_url}")

                case download_file(download_url) do
                  {:ok, binary_data} ->
                    IO.puts("Applying update...")
                    temp_path = "#{bin_path}.tmp"

                    try do
                      File.write!(temp_path, binary_data)
                      File.chmod!(temp_path, 0o755)
                      File.rename!(temp_path, bin_path)
                      IO.puts("Successfully upgraded Caudata to #{latest_tag}!")

                      # Trigger the new binary to unpack itself and uninstall older versions immediately
                      case System.cmd(bin_path, ["--version"], stderr_to_stdout: true) do
                        {output, 0} ->
                          # Print the launcher's output (like "Uninstalled older version") to the user
                          IO.write(output)

                        _ ->
                          :ok
                      end
                    rescue
                      e ->
                        IO.puts(:stderr, "Failed to apply update: #{Exception.message(e)}")

                        IO.puts(
                          :stderr,
                          "You might need to run this command with administrative privileges (e.g., sudo caudata upgrade)."
                        )

                        System.halt(1)
                    after
                      File.rm(temp_path)
                    end

                  {:error, reason} ->
                    IO.puts(:stderr, "Failed to download update: #{inspect(reason)}")
                    System.halt(1)
                end

              {:error, reason} ->
                IO.puts(:stderr, "Cannot determine system target for update: #{reason}")
                System.halt(1)
            end

          {:error, :not_in_burrito} ->
            IO.puts(
              "Self-upgrade is only supported when running as a compiled standalone binary."
            )

            IO.puts(
              "If you compiled from source, please run: git pull && mix deps.get && MIX_ENV=prod mix release"
            )

            System.halt(0)
        end

      :no_update ->
        IO.puts("Caudata is already up-to-date (v#{get_current_version()}).")

      {:error, reason} ->
        IO.puts(:stderr, "Failed to check for updates: #{inspect(reason)}")
        System.halt(1)
    end
  end

  def get_binary_path do
    if Code.ensure_loaded?(Burrito.Util.Args) do
      case Burrito.Util.Args.get_bin_path() do
        :not_in_burrito -> {:error, :not_in_burrito}
        path when is_binary(path) -> {:ok, path}
      end
    else
      {:error, :not_in_burrito}
    end
  end

  defp get_latest_tag do
    url = "https://api.github.com/repos/#{@owner}/#{@repo}/releases/latest"

    case download_json(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, %{"tag_name" => tag_name}} -> {:ok, tag_name}
          _ -> {:error, "Invalid JSON structure from GitHub API"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_json(url) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    headers = [{~c"user-agent", ~c"caudata-updater"}]
    http_opts = [autoredirect: true, timeout: 10_000]
    opts = [body_format: :binary]

    case :httpc.request(:get, {to_charlist(url), headers}, http_opts, opts) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp download_file(url) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    headers = [{~c"user-agent", ~c"caudata-updater"}]
    http_opts = [autoredirect: true, timeout: 60_000]
    opts = [body_format: :binary]

    case :httpc.request(:get, {to_charlist(url), headers}, http_opts, opts) do
      {:ok, {{_, 200, _}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_, status, _}, _, _}} ->
        {:error, "HTTP status #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_target do
    os =
      case :os.type() do
        {:unix, :darwin} -> :darwin
        {:unix, :linux} -> :linux
        other -> other
      end

    case System.cmd("uname", ["-m"]) do
      {arch, 0} ->
        arch = String.trim(arch)

        case {os, arch} do
          {:darwin, "x86_64"} -> {:ok, "macos_x86_64"}
          {:darwin, "arm64"} -> {:ok, "macos_aarch64"}
          {:darwin, "aarch64"} -> {:ok, "macos_aarch64"}
          {:linux, "x86_64"} -> {:ok, "linux_x86_64"}
          {:linux, "amd64"} -> {:ok, "linux_x86_64"}
          _ -> {:error, "Unsupported OS: #{inspect(os)} / Arch: #{arch}"}
        end

      _ ->
        {:error, "Could not run uname -m"}
    end
  end

  @doc """
  Compares two version strings. Returns `:lt`, `:gt`, or `:eq`.
  """
  def compare_versions(v1, v2) do
    v1_parts = parse_vsn_string(v1)
    v2_parts = parse_vsn_string(v2)

    case {v1_parts, v2_parts} do
      {[maj1, min1, pat1], [maj2, min2, pat2]} ->
        cond do
          maj1 < maj2 -> :lt
          maj1 > maj2 -> :gt
          min1 < min2 -> :lt
          min1 > min2 -> :gt
          pat1 < pat2 -> :lt
          pat1 > pat2 -> :gt
          true -> :eq
        end

      _ ->
        cond do
          v1 < v2 -> :lt
          v1 > v2 -> :gt
          true -> :eq
        end
    end
  end

  defp parse_vsn_string(vsn) do
    clean_vsn =
      vsn
      |> String.split("+")
      |> List.first()
      |> String.split("-")
      |> List.first()

    case String.split(clean_vsn, ".") do
      [maj, min, pat] ->
        case {Integer.parse(maj), Integer.parse(min), Integer.parse(pat)} do
          {{maj_num, _}, {min_num, _}, {pat_num, _}} ->
            [maj_num, min_num, pat_num]

          _ ->
            parse_original(vsn)
        end

      _ ->
        parse_original(vsn)
    end
  end

  defp parse_original(vsn) do
    vsn
    |> String.split(".")
    |> Enum.map(fn part ->
      case Integer.parse(part) do
        {num, _} -> num
        :error -> 0
      end
    end)
  end
end
