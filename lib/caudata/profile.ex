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
    port: 22,
    log_command: "tail -F /var/log/messages",
    disabled_containers: [],
    custom_logs: [],
    enabled: true
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          host_pattern: String.t(),
          host_name: String.t() | nil,
          user: String.t() | nil,
          port: integer(),
          identity_file: String.t() | nil,
          password: String.t() | nil,
          log_command: String.t(),
          disabled_containers: [String.t()],
          custom_logs: [String.t()],
          enabled: boolean()
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

    struct!(
      __MODULE__,
      Map.merge(
        %{
          id: id,
          host_name: host_pattern,
          port: 22,
          log_command: "tail -F /var/log/messages",
          disabled_containers: [],
          custom_logs: [],
          enabled: true
        },
        clean_attrs
      )
    )
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
    struct(__MODULE__, fields)
  end
end
