defmodule Caudata.Profile do
  @moduledoc """
  Defines the structure for an SSH connection profile.
  """

  @enforce_keys [:id, :host_pattern]
  defstruct [
    :id,
    :host_pattern,
    :host_name,
    :user,
    :identity_file,
    :password,
    auth_method: :auto,
    ssh_agent_socket: nil,
    port: 22,
    disabled_containers: [],
    custom_logs: [],
    enabled_services: [],
    enabled: true,
    is_local: false
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          host_pattern: String.t(),
          host_name: String.t() | nil,
          user: String.t() | nil,
          port: integer(),
          identity_file: String.t() | nil,
          password: String.t() | nil,
          auth_method: :auto | :key | :agent | :password,
          ssh_agent_socket: String.t() | nil,
          disabled_containers: [String.t()],
          custom_logs: [String.t()],
          enabled_services: [String.t()],
          enabled: boolean(),
          is_local: boolean()
        }

  @doc """
  Creates a profile struct with sensible defaults.
  """
  def new(attrs) do
    host_pattern = Map.get(attrs, :host_pattern) || Map.get(attrs, "host_pattern")
    id = Map.get(attrs, :id) || Map.get(attrs, "id") || host_pattern

    if is_nil(host_pattern) do
      raise ArgumentError, "host_pattern is required"
    end

    # Reject nil values from attrs to let defaults show through
    clean_attrs =
      Map.new(attrs, fn {k, v} -> {to_existing_atom(k), v} end)
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    profile =
      struct!(
        __MODULE__,
        Map.merge(
          %{
            id: id,
            host_name: host_pattern,
            port: 22,
            auth_method: :auto,
            ssh_agent_socket: nil,
            disabled_containers: [],
            custom_logs: [],
            enabled_services: [],
            enabled: true,
            is_local: false
          },
          clean_attrs
        )
      )

    %{profile | auth_method: normalize_auth_method(profile.auth_method)}
  end

  @doc """
  Normalizes auth_method to a supported atom (:auto, :key, :agent, :password).
  Defaults to :auto for unrecognized values.
  """
  def normalize_auth_method(auth_method) do
    case auth_method do
      m when m in [:auto, :key, :agent, :password] -> m
      m when m in ["auto", "key", "agent", "password"] -> String.to_existing_atom(m)
      _ -> :auto
    end
  end

  @doc """
  Builds standard SSH connection options from a Profile struct or map.
  Preserves backward compatibility by omitting default/empty options.
  """
  def to_connect_opts(%__MODULE__{} = profile) do
    [
      user: profile.user,
      identity_file: profile.identity_file,
      password: profile.password
    ]
    |> then(fn opts ->
      case normalize_auth_method(profile.auth_method) do
        :auto -> opts
        m -> Keyword.put(opts, :auth_method, m)
      end
    end)
    |> then(fn opts ->
      case profile.ssh_agent_socket do
        s when is_binary(s) and s != "" -> Keyword.put(opts, :ssh_agent_socket, s)
        _ -> opts
      end
    end)
  end

  def to_connect_opts(profile) when is_map(profile) do
    profile
    |> ensure_struct_fields()
    |> to_connect_opts()
  end

  defp to_existing_atom(k) when is_atom(k), do: k

  defp to_existing_atom(k) when is_binary(k) do
    try do
      String.to_existing_atom(k)
    rescue
      ArgumentError -> String.to_atom(k)
    end
  end

  @doc """
  Ensures that the profile has all current struct fields.
  Useful when loading profiles from older serialized configurations.
  """
  def ensure_struct_fields(profile) when is_map(profile) do
    # Strip __struct__ if present, and rebuild the struct with current defaults.
    fields = Map.delete(profile, :__struct__)
    prof = struct(__MODULE__, fields)
    %{prof | auth_method: normalize_auth_method(prof.auth_method)}
  end
end
