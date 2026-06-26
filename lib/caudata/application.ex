defmodule Caudata.Application do
  @moduledoc false
  use Application
  require Logger

  @env Application.compile_env(:caudata, :env, :prod)

  @impl true
  def start(_type, _args) do
    # Handle command-line arguments if not running in test mode
    mode =
      if @env != :test do
        Caudata.CLI.handle_args(Burrito.Util.Args.argv())
      else
        :continue
      end

    if match?({:web, _}, mode) do
      {:web, port} = mode
      endpoint_config = Application.get_env(:caudata, Caudata.Web.Endpoint, [])
      http_config = Keyword.get(endpoint_config, :http, [])
      http_config = Keyword.put(http_config, :port, port)

      endpoint_config =
        endpoint_config
        |> Keyword.put(:server, true)
        |> Keyword.put(:http, http_config)

      Application.put_env(:caudata, Caudata.Web.Endpoint, endpoint_config)

      ip_str = System.get_env("CAUDATA_IP") || "127.0.0.1"
      IO.puts("Caudata Web Server is starting on http://#{ip_str}:#{port}")
    end

    # Load configuration
    {:ok, config} = Caudata.Config.load()
    capacity = Caudata.Config.global_capacity(config)
    _ssh_settings = Caudata.Config.ssh_server_settings(config)

    # Disable console logging if starting TUI to prevent corrupting the terminal render
    if start_tui?(mode) do
      Logger.configure(backends: [])
      :logger.set_primary_config(:level, :none)
    end

    children = [
      # Event bus for status and log updates
      Supervisor.child_spec({Phoenix.PubSub, name: Caudata.PubSub}, id: :pubsub_caudata),

      # Config Manager for loading profile configs
      {Caudata.ConfigManager, []},

      # Log Store for keeping bounded log queues
      {Caudata.LogStore, [capacity: capacity]},

      # Server registry for worker naming lookup
      {Registry, keys: :unique, name: Caudata.ServerRegistry},

      # Server DynamicSupervisor for dynamically spawned server workers
      Caudata.ServerSupervisor
    ]

    # Define children based on environment and TUI startup decision
    children =
      cond do
        match?({:web, _}, mode) ->
          children ++ [Caudata.Web.Endpoint]

        @env != :prod and start_tui?(mode) ->
          children ++ [Caudata.Web.Endpoint, {Caudata.UI.App, [terminal: true]}]

        @env != :prod ->
          children ++ [Caudata.Web.Endpoint]

        start_tui?(mode) ->
          children ++ [{Caudata.UI.App, [terminal: true]}]

        true ->
          children
      end

    opts = [strategy: :one_for_one, name: Caudata.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_tui?(mode) do
    cond do
      match?({:web, _}, mode) ->
        false

      System.get_env("CAUDATA_TUI") == "false" ->
        false

      System.get_env("CAUDATA_TUI") == "true" ->
        true

      @env == :test ->
        false

      @env == :dev ->
        false

      Code.ensure_loaded?(IEx) && IEx.started?() ->
        false

      System.get_env("TERM") not in [nil, "", "dumb"] ->
        true

      match?({:ok, _}, :io.columns()) ->
        true

      true ->
        false
    end
  end
end
