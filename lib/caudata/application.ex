defmodule Caudata.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    # Load configuration
    {:ok, config} = Caudata.Config.load()
    capacity = Caudata.Config.global_capacity(config)
    _ssh_settings = Caudata.Config.ssh_server_settings(config)

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
      Caudata.ServerSupervisor,

      # Phoenix Endpoint
      Caudata.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Caudata.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
