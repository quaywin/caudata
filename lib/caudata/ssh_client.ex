defmodule Caudata.SSHClient do
  @moduledoc """
  Defines the SSH connection behaviour and its Native implementation wrapping Erlang's :ssh.
  """

  @callback connect(String.t(), integer(), list()) :: {:ok, term()} | {:error, any()}
  @callback open_channel(term()) :: {:ok, term()} | {:error, any()}
  @callback exec(term(), term(), String.t()) :: :ok | {:error, any()}
  @callback close_channel(term(), term()) :: :ok
  @callback close(term()) :: :ok

  defmodule Native do
    @behaviour Caudata.SSHClient
    require Logger

    @impl true
    def connect(host, port, opts) do
      # Convert host and user to charlists for Erlang :ssh
      char_host = to_charlist(host)
      user = Keyword.get(opts, :user)
      identity_file = Keyword.get(opts, :identity_file)

      # Build standard options
      ssh_opts = [
        user: to_charlist(user),
        silently_accept_hosts: false,
        user_interaction: false
      ]

      # Add user directory if ~/.ssh is available
      user_dir = Path.expand("~/.ssh")

      ssh_opts =
        if File.dir?(user_dir) do
          Keyword.put(ssh_opts, :user_dir, to_charlist(user_dir))
        else
          ssh_opts
        end

      # Add identity file callback options if identity_file is specified
      ssh_opts =
        if identity_file && File.exists?(identity_file) do
          # Use our custom KeyCallback module and pass the identity_file path
          Keyword.put(
            ssh_opts,
            :key_cb,
            {Caudata.SSHClient.KeyCallback, [key_cb_private: identity_file]}
          )
        else
          ssh_opts
        end

      case :ssh.connect(char_host, port, ssh_opts) do
        {:ok, conn_ref} ->
          {:ok, conn_ref}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def open_channel(conn_ref) do
      # Open a session type channel
      # 5000ms timeout
      case :ssh_connection.session_channel(conn_ref, 5000) do
        {:ok, channel_id} ->
          {:ok, channel_id}

        {:error, reason} ->
          {:error, reason}

        {:open_error, reason_code, description, lang} ->
          {:error, {:open_error, reason_code, description, lang}}

        other ->
          {:error, other}
      end
    end

    @impl true
    def exec(conn_ref, channel_id, command) do
      # Executes a command on the session channel
      # Note: Erlang's :ssh_connection.exec returns a :success or :failure atom or tuple
      case :ssh_connection.exec(conn_ref, channel_id, to_charlist(command), 5000) do
        :success ->
          :ok

        :failure ->
          {:error, :exec_failure}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def close_channel(conn_ref, channel_id) do
      # Close a channel on the connection
      :ssh_connection.close(conn_ref, channel_id)
      :ok
    end

    @impl true
    def close(conn_ref) do
      :ssh.close(conn_ref)
      :ok
    end
  end
end

defmodule Caudata.SSHClient.KeyCallback do
  @behaviour :ssh_client_key_api
  require Logger

  @impl true
  def add_host_key(_host, _port, _public_key, _options) do
    :ok
  end

  @impl true
  def is_host_key(_public_key, _host, _port, _algorithm, _options) do
    true
  end

  @impl true
  def user_key(algorithm, options) do
    Logger.debug(
      "SSH KeyCallback: user_key requested for algorithm #{inspect(algorithm)} with options: #{inspect(options)}"
    )

    case Keyword.get(options, :key_cb_private) do
      nested when is_list(nested) ->
        case Keyword.get(nested, :key_cb_private) do
          identity_file when is_binary(identity_file) ->
            case File.read(identity_file) do
              {:ok, pem_binary} ->
                try do
                  case :public_key.pem_decode(pem_binary) do
                    [entry | _] = entries ->
                      Logger.debug(
                        "SSH KeyCallback: found #{length(entries)} PEM entries in #{identity_file}"
                      )

                      case entry do
                        {tag, _data, _cipher} when is_tuple(tag) and elem(tag, 0) == :no_asn1 ->
                          case :ssh_file.decode(pem_binary, :public_key) do
                            [{private_key, _attributes} | _rest] ->
                              Logger.debug(
                                "SSH KeyCallback: successfully decoded private key using :ssh_file.decode/2"
                              )

                              {:ok, private_key}

                            other ->
                              Logger.debug(
                                "SSH KeyCallback: failed to decode OpenSSH key: #{inspect(other)}"
                              )

                              {:error, "Failed to decode OpenSSH key"}
                          end

                        _ ->
                          private_key = :public_key.pem_entry_decode(entry)

                          Logger.debug(
                            "SSH KeyCallback: successfully decoded private key of type #{inspect(elem(private_key, 0))}"
                          )

                          {:ok, private_key}
                      end

                    _ ->
                      Logger.debug("SSH KeyCallback: No PEM entries found in #{identity_file}")
                      {:error, "No PEM entries found"}
                  end
                rescue
                  e ->
                    Logger.debug(
                      "SSH KeyCallback: Failed to decode key in #{identity_file}: #{inspect(e)}"
                    )

                    {:error, "Failed to decode key: #{inspect(e)}"}
                end

              {:error, reason} ->
                Logger.debug(
                  "SSH KeyCallback: Failed to read identity file #{identity_file}: #{inspect(reason)}"
                )

                {:error, "Failed to read identity file: #{inspect(reason)}"}
            end

          _ ->
            Logger.debug("SSH KeyCallback: identity_file is not a binary")
            {:error, "identity_file is not a binary"}
        end

      _ ->
        Logger.debug("SSH KeyCallback: No identity file specified in options")
        {:error, "No identity file specified"}
    end
  end
end
