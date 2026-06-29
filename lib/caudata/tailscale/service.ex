defmodule Caudata.Tailscale.Service do
  use GenServer
  require Logger

  # Client APIs

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def active? do
    if GenServer.whereis(__MODULE__), do: GenServer.call(__MODULE__, :active?), else: false
  end

  def get_device do
    GenServer.call(__MODULE__, :get_device)
  end

  def get_ip do
    GenServer.call(__MODULE__, :get_ip)
  end

  @doc """
  Checks if a host is a Tailscale IP (starts with 100.x) or ends with `.ts.net` (MagicDNS).
  """
  def tailscale_host?(host) do
    cond do
      is_nil(host) ->
        false

      String.match?(host, ~r/^100\.(6[4-9]|[7-9]\d|1[0-1]\d|12[0-7])\.\d+\.\d+$/) ->
        true

      String.ends_with?(host, ".ts.net") ->
        true

      true ->
        false
    end
  end

  @doc """
  Sets up a local TCP proxy that forwards to the target Tailscale host:port.
  Returns {:ok, proxy_pid, {local_ip, local_port}}
  """
  def get_ssh_proxy(host, port) do
    if active?() do
      dev = get_device()
      Caudata.Tailscale.SSHProxy.start_proxy(dev, host, port)
    else
      {:error, :tailscale_not_active}
    end
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Stop any stale proxy processes to release the Tailscale device reference and disconnect
    stop_all_proxies()

    # Load configuration directly from ConfigStore if it's running, falling back to Config.load()
    ts_config =
      if Process.whereis(Caudata.ConfigStore) do
        %{
          enabled:
            Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :tailscale, :enabled, false),
          auth_key:
            Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :tailscale, :auth_key, ""),
          hostname:
            Caudata.ConfigStore.get_setting(Caudata.ConfigStore, :tailscale, :hostname, "caudata")
        }
      else
        {:ok, config} = Caudata.Config.load()
        Caudata.Config.tailscale_settings(config)
      end

    # Hybrid mode: environment variables override settings
    env_auth_key = System.get_env("TAILSCALE_AUTHKEY")

    auth_key = if env_auth_key && env_auth_key != "", do: env_auth_key, else: ts_config.auth_key
    enabled = ts_config.enabled || env_auth_key != nil
    hostname = ts_config.hostname

    if enabled && auth_key && auth_key != "" do
      key_file = Path.expand("~/.caudata/tailscale_key.json")
      File.mkdir_p!(Path.dirname(key_file))

      state = %{
        dev: nil,
        ip: nil,
        status: :connecting,
        auth_key: auth_key,
        key_file: key_file,
        hostname: hostname,
        error: nil
      }

      {:ok, state, {:continue, :connect}}
    else
      {:ok, %{status: :inactive}}
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    Logger.info("Initializing user-space Tailscale node asynchronously...")
    broadcast_ts({:tailscale_status, :connecting})
    parent = self()

    Task.start(fn ->
      # Automatically acknowledge tailscale-rs experimental status as required by the library
      System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")

      case Tailscale.connect(state.key_file, auth_key: state.auth_key, hostname: state.hostname) do
        {:ok, dev} ->
          case Tailscale.ipv4_addr(dev) do
            {:ok, ip_tuple} ->
              ip_str = :inet.ntoa(ip_tuple) |> to_string()
              send(parent, {:ts_connected, dev, ip_str})

            {:error, err} ->
              send(parent, {:ts_connect_failed, err})
          end

        {:error, err} ->
          send(parent, {:ts_connect_failed, err})
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_info({:ts_connected, dev, ip_str}, state) do
    Logger.info("Tailscale connected successfully! IP: #{ip_str}")

    # Broadcast event to trigger immediate reconnect for any waiting server workers
    Phoenix.PubSub.broadcast(Caudata.PubSub, "tailscale", :tailscale_connected)
    broadcast_ts({:tailscale_status, {:connected, ip_str}})

    {:noreply, %{state | dev: dev, ip: ip_str, status: :active}}
  end

  @impl true
  def handle_info({:ts_connect_failed, err}, state) do
    Logger.error("Failed to connect to Tailscale network: #{inspect(err)}")
    broadcast_ts({:tailscale_status, {:error, err}})
    {:noreply, %{state | status: :error, error: err}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_call(:active?, _from, state) do
    {:reply, Map.get(state, :status) == :active, state}
  end

  @impl true
  def handle_call(:get_device, _from, state) do
    {:reply, Map.get(state, :dev), state}
  end

  @impl true
  def handle_call(:get_ip, _from, state) do
    {:reply, Map.get(state, :ip), state}
  end

  # Helpers

  defp broadcast_ts(msg) do
    if Process.whereis(Caudata.PubSub) do
      Phoenix.PubSub.broadcast(Caudata.PubSub, "tailscale", msg)
    end
  end

  defp stop_all_proxies do
    if Process.whereis(Caudata.ServerSupervisor) do
      DynamicSupervisor.which_children(Caudata.ServerSupervisor)
      |> Enum.each(fn
        {_, pid, _, [Caudata.Tailscale.SSHProxy]} ->
          DynamicSupervisor.terminate_child(Caudata.ServerSupervisor, pid)

        _ ->
          :ok
      end)
    end
  end
end
