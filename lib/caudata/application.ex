defmodule Caudata.Application do
  @moduledoc false
  use Application
  require Logger

  @env Application.compile_env(:caudata, :env, :prod)

  @impl true
  def start(_type, _args) do
    args =
      if Code.ensure_loaded?(Burrito.Util.Args) do
        Burrito.Util.Args.argv()
      else
        System.argv()
      end

    if @env != :test do
      Caudata.CLI.handle_args(args)
    end

    # Load configuration
    {:ok, config} = Caudata.Config.load()
    capacity = Caudata.Config.global_capacity(config)
    _ssh_settings = Caudata.Config.ssh_server_settings(config)

    # Setup file logging in ~/.caudata/caudata.log
    log_dir = Path.expand("~/.caudata")
    File.mkdir_p!(log_dir)
    log_file = Path.join(log_dir, "caudata.log")

    try do
      :logger.add_handler(:caudata_file_log, :logger_std_h, %{
        config: %{type: :file, file: String.to_charlist(log_file)},
        level: :info
      })
    catch
      _, _ -> :ok
    end

    # Disable console logging if starting TUI to prevent corrupting the terminal render
    if start_tui?() do
      Logger.configure(backends: [])
      _ = :logger.remove_handler(:default)
      :logger.set_primary_config(:level, :info)

      :os.set_signal(:sighup, :handle)
      :os.set_signal(:sigterm, :handle)
      :gen_event.add_handler(:erl_signal_server, Caudata.SignalHandler, [])
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

    children =
      if start_tui?(),
        do: children ++ [{Caudata.UI.App, [terminal: true, mouse_capture: true]}],
        else: children

    opts = [strategy: :one_for_one, name: Caudata.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_tui? do
    cond do
      System.get_env("CAUDATA_TUI") == "false" ->
        false

      System.get_env("CAUDATA_TUI") == "true" ->
        true

      @env == :test ->
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
