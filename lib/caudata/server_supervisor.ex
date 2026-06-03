defmodule Caudata.ServerSupervisor do
  use DynamicSupervisor
  require Logger
  alias Caudata.ServerWorker

  def start_link(init_arg) do
    DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)
  end

  @doc """
  Starts a log streamer worker process for the given profile.
  """
  def start_worker(profile, opts \\ []) do
    spec = {ServerWorker, {profile, opts}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        Logger.info("Started ServerWorker for #{profile.id} under supervisor")
        {:ok, pid}

      {:ok, pid, _info} ->
        Logger.info("Started ServerWorker for #{profile.id} under supervisor")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        Logger.info("ServerWorker for #{profile.id} is already running")
        {:ok, pid}

      {:error, reason} ->
        Logger.error("Failed to start ServerWorker for #{profile.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Starts a container worker process for the given profile_id and container metadata.
  """
  def start_container_worker(profile_id, container, opts \\ []) do
    spec = {Caudata.ContainerWorker, {profile_id, container, opts}}

    case DynamicSupervisor.start_child(__MODULE__, spec) do
      {:ok, pid} ->
        {:ok, pid}

      {:ok, pid, _info} ->
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} ->
        Logger.error(
          "Failed to start ContainerWorker for #{profile_id}/#{container.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end

  @doc """
  Stops a container worker process.
  """
  def stop_container_worker(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  @doc """
  Finds the active ContainerWorker pid by its profile ID and container ID.
  """
  def lookup_container_worker(profile_id, container_id) do
    case Registry.lookup(Caudata.ServerRegistry, {:container, profile_id, container_id}) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Stops the log streamer worker process for the given source ID.
  """
  def stop_worker(source_id) do
    case lookup_worker(source_id) do
      {:ok, pid} ->
        DynamicSupervisor.terminate_child(__MODULE__, pid)
        Logger.info("Stopped ServerWorker for #{source_id} successfully")
        :ok

      {:error, :not_found} ->
        Logger.warning("Cannot stop worker: ServerWorker for #{source_id} not found")
        {:error, :not_found}
    end
  end

  @doc """
  Finds the active ServerWorker pid by its source ID.
  """
  def lookup_worker(source_id) do
    case Registry.lookup(Caudata.ServerRegistry, source_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
