defmodule Caudata.ConfigManager do
  use GenServer
  require Logger
  alias Caudata.Profile

  @default_config_path "~/.ssh/config"

  # Client API

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Lists all loaded and manual profiles.
  """
  def list_profiles(server \\ __MODULE__) do
    GenServer.call(server, :list_profiles)
  end

  @doc """
  Gets a specific profile by its ID.
  """
  def get_profile(server \\ __MODULE__, id) do
    GenServer.call(server, {:get_profile, id})
  end

  @doc """
  Adds a manual connection profile.
  """
  def add_manual_profile(server \\ __MODULE__, attrs) do
    GenServer.call(server, {:add_manual_profile, attrs})
  end

  @doc """
  Discovers profiles from the configured SSH config path.
  """
  def discover_ssh_profiles(server \\ __MODULE__) do
    GenServer.call(server, :discover_ssh_profiles)
  end

  # GenServer Callbacks

  @impl true
  def init(opts) do
    {:ok, config} = Caudata.Config.load()
    custom_profiles = Caudata.Config.custom_profiles(config)

    ssh_config_path =
      Keyword.get(opts, :ssh_config_path) || System.get_env("CAUDATA_SSH_CONFIG_PATH") ||
        @default_config_path

    {:ok, %{profiles: custom_profiles, manual_profiles: [], ssh_config_path: ssh_config_path}}
  end

  @impl true
  def handle_call(:list_profiles, _from, state) do
    all_profiles = state.profiles ++ state.manual_profiles
    {:reply, all_profiles, state}
  end

  @impl true
  def handle_call({:get_profile, id}, _from, state) do
    all_profiles = state.profiles ++ state.manual_profiles
    profile = Enum.find(all_profiles, fn p -> p.id == id end)
    {:reply, profile, state}
  end

  @impl true
  def handle_call(:discover_ssh_profiles, _from, state) do
    expanded_path = Path.expand(state.ssh_config_path)

    profiles =
      if File.exists?(expanded_path) do
        case parse_ssh_config(expanded_path) do
          {:ok, list} ->
            Logger.info("Discovered #{length(list)} profiles from SSH config at #{expanded_path}")
            list

          {:error, reason} ->
            Logger.warning("Failed to parse SSH config at #{expanded_path}: #{inspect(reason)}")
            []
        end
      else
        Logger.info("No SSH config file found at #{expanded_path}")
        []
      end

    {:reply, profiles, state}
  end

  @impl true
  def handle_call({:add_manual_profile, attrs}, _from, state) do
    try do
      profile = Profile.new(attrs)
      profile_map = Map.from_struct(profile)

      # Persist manual profile to config.toml
      :ok = Caudata.Config.append_profile(profile_map)

      new_manual = [profile | state.manual_profiles]

      # Broadcast profiles update (if PubSub is available)
      Phoenix.PubSub.broadcast(
        Caudata.PubSub,
        "config:profiles",
        {:profiles_updated, state.profiles ++ new_manual}
      )

      {:reply, {:ok, profile}, %{state | manual_profiles: new_manual}}
    rescue
      e ->
        {:reply, {:error, e}, state}
    end
  end

  # Parsing Logic

  @doc """
  Parses an SSH config file and returns a list of profiles.
  """
  def parse_ssh_config(path) do
    expanded_path = Path.expand(path)

    if File.exists?(expanded_path) do
      lines = read_lines_recursive(expanded_path, [])

      profiles =
        lines
        |> Enum.reduce({[], nil}, &parse_line/2)
        |> finalize_last_profile()

      {:ok, profiles}
    else
      {:error, :enoent}
    end
  end

  defp read_lines_recursive(path, visited) do
    expanded_path = Path.expand(path)

    if expanded_path in visited or not File.exists?(expanded_path) do
      []
    else
      visited = [expanded_path | visited]
      config_dir = Path.dirname(expanded_path)

      case File.read(expanded_path) do
        {:ok, content} ->
          content
          |> String.split(["\r\n", "\n"])
          |> Enum.flat_map(fn line ->
            trimmed = String.trim(line)
            clean_line = strip_inline_comment(trimmed)

            case String.split(clean_line, ~r{[\s=]+}, parts: 2) do
              [key, val] ->
                directive = String.downcase(String.trim(key))
                value = String.trim(val)

                if directive == "include" do
                  resolved_pattern = expand_include_path(value, config_dir)

                  Path.wildcard(resolved_pattern)
                  |> Enum.flat_map(fn child_path ->
                    read_lines_recursive(child_path, visited)
                  end)
                else
                  [line]
                end

              _ ->
                [line]
            end
          end)

        {:error, _} ->
          []
      end
    end
  end

  defp expand_include_path(value, config_dir) do
    clean_val = String.replace(value, ~r{^"|"$}, "")

    cond do
      String.starts_with?(clean_val, "~") ->
        Path.expand(clean_val)

      Path.type(clean_val) == :absolute ->
        clean_val

      true ->
        Path.join(config_dir, clean_val)
    end
  end

  defp parse_line(line, {acc, current}) do
    trimmed = String.trim(line)

    if trimmed == "" or String.starts_with?(trimmed, "#") do
      {acc, current}
    else
      clean_line = strip_inline_comment(trimmed)

      case String.split(clean_line, ~r{[\s=]+}, parts: 2) do
        [key, val] ->
          directive = String.downcase(String.trim(key))
          value = String.trim(val)
          handle_directive(directive, value, acc, current)

        _ ->
          {acc, current}
      end
    end
  end

  defp strip_inline_comment(line) do
    line
    |> String.split("#", parts: 2)
    |> List.first()
    |> String.trim()
  end

  defp handle_directive("host", value, acc, current) do
    acc = if current, do: [build_profile(current) | acc], else: acc
    host_pattern = List.first(String.split(value, ~r{\s+}))

    new_profile = %{
      id: host_pattern,
      host_pattern: host_pattern,
      host_name: host_pattern,
      port: 22,
      identity_file: nil,
      user: nil
    }

    {acc, new_profile}
  end

  defp handle_directive("hostname", value, acc, current) when not is_nil(current) do
    {acc, Map.put(current, :host_name, value)}
  end

  defp handle_directive("user", value, acc, current) when not is_nil(current) do
    {acc, Map.put(current, :user, value)}
  end

  defp handle_directive("port", value, acc, current) when not is_nil(current) do
    port =
      case Integer.parse(value) do
        {int, _} -> int
        _ -> 22
      end

    {acc, Map.put(current, :port, port)}
  end

  defp handle_directive("identityfile", value, acc, current) when not is_nil(current) do
    clean_val = String.replace(value, ~r{^"|"$}, "")
    expanded = Path.expand(clean_val)
    {acc, Map.put(current, :identity_file, expanded)}
  end

  defp handle_directive(_, _value, acc, current) do
    {acc, current}
  end

  defp finalize_last_profile({acc, nil}) do
    acc
    |> Enum.reverse()
    |> Enum.filter(&valid_profile?/1)
  end

  defp finalize_last_profile({acc, current}) do
    [build_profile(current) | acc]
    |> Enum.reverse()
    |> Enum.filter(&valid_profile?/1)
  end

  defp valid_profile?(profile) do
    not (String.contains?(profile.host_pattern, "*") or
           String.contains?(profile.host_pattern, "?"))
  end

  defp build_profile(map) do
    Profile.new(map)
  end
end
