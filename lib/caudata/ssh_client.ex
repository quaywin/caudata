defmodule Caudata.SSHClient do
  @moduledoc """
  Defines the SSH connection behaviour and its Native implementation wrapping Erlang's :ssh.
  """

  @callback connect(String.t(), integer(), list()) :: {:ok, term()} | {:error, any()}
  @callback open_channel(term()) :: {:ok, term()} | {:error, any()}
  @callback exec(term(), term(), String.t()) :: :ok | {:error, any()}
  @callback adjust_window(term(), term(), non_neg_integer()) :: :ok | {:error, any()}
  @callback close_channel(term(), term()) :: :ok
  @callback close(term()) :: :ok

  defmodule Native do
    @behaviour Caudata.SSHClient
    require Logger

    @channel_timeout 5_000

    @impl true
    def connect(host, port, opts) do
      user =
        case Keyword.get(opts, :user) do
          nil -> nil
          val -> to_string(val)
        end

      if is_nil(user) or user == "" do
        {:error, :missing_user}
      else
        do_connect(host, port, user, opts)
      end
    end

    defp do_connect(host, port, user, opts) do
      char_host = to_charlist(host)

      identity_file =
        case Keyword.get(opts, :identity_file) do
          nil -> nil
          val -> to_string(val)
        end

      password =
        case Keyword.get(opts, :password) do
          nil -> nil
          val -> to_string(val)
        end

      # Build standard options
      # silently_accept_hosts: true — this is an internal tool, host key verification
      # is handled by KeyCallback.is_host_key/5 when a custom key_cb is set.
      ssh_opts = [
        user: to_charlist(user),
        silently_accept_hosts: true,
        user_interaction: false,
        connect_timeout: 10_000,
        socket_options: [
          keepalive: true,
          nodelay: true
        ],
        preferred_algorithms: [
          compression: [:zlib, :"zlib@openssh.com", :none]
        ]
      ]

      # Check for SSH agent socket
      custom_agent_sock =
        case Keyword.get(opts, :ssh_agent_socket) do
          nil -> nil
          val -> to_string(val)
        end

      auth_method =
        case Keyword.get(opts, :auth_method, :auto) do
          m when m in [:auto, :key, :agent, :password] -> m
          m when m in ["auto", "key", "agent", "password"] -> String.to_existing_atom(m)
          _ -> :auto
        end

      has_password = not is_nil(password) and password != ""
      has_valid_identity_file = not is_nil(identity_file) and File.exists?(identity_file)
      user_dir = Path.expand("~/.ssh")

      # Probe for live SSH agent socket
      agent_sock_res =
        if auth_method in [:auto, :agent] do
          Caudata.SSH.Agent.get_live_socket(custom_agent_sock)
        else
          :none
        end

      # Add password if specified and auth_method allows
      ssh_opts =
        if has_password and auth_method != :agent do
          Keyword.put(ssh_opts, :password, to_charlist(password))
        else
          ssh_opts
        end

      # Add user directory if ~/.ssh is available and auth_method allows
      ssh_opts =
        if File.dir?(user_dir) and auth_method != :password and
             (not has_password or has_valid_identity_file or match?({:ok, _}, agent_sock_res) or
                auth_method in [:key, :agent]) do
          Keyword.put(ssh_opts, :user_dir, to_charlist(user_dir))
        else
          ssh_opts
        end

      # Configure key callback (identity file, live agent socket, or both)
      key_cb_opts =
        if auth_method == :password do
          nil
        else
          agent_sock =
            case agent_sock_res do
              {:ok, sock} -> sock
              _ -> nil
            end

          cond do
            has_valid_identity_file and agent_sock ->
              [identity_file: identity_file, agent_socket: agent_sock]

            has_valid_identity_file ->
              [identity_file: identity_file]

            agent_sock ->
              [agent_socket: agent_sock]

            true ->
              nil
          end
        end

      ssh_opts =
        if key_cb_opts do
          Keyword.put(
            ssh_opts,
            :key_cb,
            {Caudata.SSHClient.KeyCallback, key_cb_opts}
          )
        else
          ssh_opts
        end

      try do
        case :ssh.connect(char_host, port, ssh_opts, 10_000) do
          {:ok, conn_ref} ->
            {:ok, conn_ref}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end
    end

    @impl true
    def open_channel(conn_ref) do
      try do
        case :ssh_connection.session_channel(conn_ref, @channel_timeout) do
          {:ok, channel_id} ->
            {:ok, channel_id}

          {:error, reason} ->
            {:error, reason}

          {:open_error, reason_code, description, lang} ->
            {:error, {:open_error, reason_code, description, lang}}

          other ->
            {:error, other}
        end
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end
    end

    @impl true
    def exec(conn_ref, channel_id, command) do
      try do
        case :ssh_connection.exec(conn_ref, channel_id, to_charlist(command), @channel_timeout) do
          :success ->
            :ok

          :failure ->
            {:error, :exec_failure}

          {:error, reason} ->
            {:error, reason}
        end
      catch
        :exit, reason -> {:error, {:exit, reason}}
        kind, reason -> {:error, {kind, reason}}
      end
    end

    @impl true
    def adjust_window(conn_ref, channel_id, bytes) do
      try do
        :ssh_connection.adjust_window(conn_ref, channel_id, bytes)
      catch
        _, _ -> :ok
      end
    end

    @impl true
    def close_channel(conn_ref, channel_id) do
      try do
        _ = :ssh_connection.send_eof(conn_ref, channel_id)
      catch
        _, _ -> :ok
      end

      Task.start(fn ->
        Process.sleep(100)

        try do
          :ssh_connection.close(conn_ref, channel_id)
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    @impl true
    def close(conn_ref) do
      try do
        :ssh.close(conn_ref)
      catch
        _, _ -> :ok
      end

      :ok
    end
  end
end

defmodule Caudata.SSHClient.KeyCallback do
  @behaviour :ssh_client_key_api
  require Logger

  # Accept and persist nothing — intentional for an internal tool.
  # Host keys are trusted on every connection without being stored.
  @impl true
  def add_host_key(_host, _port, _public_key, _options) do
    :ok
  end

  @impl true
  def is_host_key(_public_key, _host, _port, _algorithm, _options) do
    true
  end

  # Required by :ssh_client_key_api on OTP 28+.
  @impl true
  def sign(key, data, options) do
    case extract_pubkey_blob(key) do
      {:ok, pubkey_blob} ->
        sign_with_agent(pubkey_blob, data, options)

      :error ->
        sign_with_private_key(key, data)
    end
  end

  defp extract_pubkey_blob({:ssh2_pubkey, blob}) when is_binary(blob), do: {:ok, blob}
  defp extract_pubkey_blob(blob) when is_binary(blob), do: {:ok, blob}
  defp extract_pubkey_blob(_), do: :error

  defp sign_with_agent(pubkey_blob, data, options) do
    socket_path = get_agent_socket(options)

    agent_opts =
      if socket_path do
        [key_cb_private: [socket_path: to_charlist(socket_path), timeout: 5000]]
      else
        options
      end

    try do
      case :ssh_agent.sign(pubkey_blob, data, agent_opts) do
        signature when is_binary(signature) ->
          signature

        other ->
          Logger.error("SSH KeyCallback: SSH Agent sign returned unexpected: #{inspect(other)}")
          <<>>
      end
    catch
      kind, reason ->
        Logger.error("SSH KeyCallback: SSH Agent sign failed: #{inspect({kind, reason})}")
        <<>>
    end
  end

  defp sign_with_private_key(key, data) do
    try do
      algorithm = sign_algorithm(key)

      case :public_key.sign(data, algorithm, key) do
        signature when is_binary(signature) ->
          signature

        other ->
          Logger.error("SSH KeyCallback: Private key sign returned unexpected: #{inspect(other)}")
          <<>>
      end
    rescue
      e ->
        Logger.error("SSH KeyCallback: Private key sign failed: #{inspect(e)}")
        <<>>
    end
  end

  @impl true
  def user_key(algorithm, options) do
    Logger.debug(
      "SSH KeyCallback: user_key requested for algorithm #{inspect(algorithm)} with options: #{inspect(options)}"
    )

    case get_identity_file(options) do
      identity_file when is_binary(identity_file) and identity_file != "" ->
        case decode_private_key(identity_file) do
          {:ok, key} ->
            {:ok, key}

          {:error, _reason} = err ->
            case get_agent_socket(options) do
              sock when is_binary(sock) and sock != "" ->
                query_ssh_agent(algorithm, sock, options)

              _ ->
                err
            end
        end

      identity_file when is_list(identity_file) and identity_file != ~c"" ->
        case decode_private_key(to_string(identity_file)) do
          {:ok, key} ->
            {:ok, key}

          {:error, _reason} = err ->
            case get_agent_socket(options) do
              sock when is_binary(sock) and sock != "" ->
                query_ssh_agent(algorithm, sock, options)

              _ ->
                err
            end
        end

      _ ->
        case get_agent_socket(options) do
          sock when is_binary(sock) and sock != "" ->
            query_ssh_agent(algorithm, sock, options)

          _ ->
            Logger.info("SSH KeyCallback: No identity file specified in options")
            {:error, "No identity file specified"}
        end
    end
  end

  # -- Private helpers --

  defp query_ssh_agent(algorithm, socket_path, _options) do
    try do
      agent_opts = [key_cb_private: [socket_path: to_charlist(socket_path), timeout: 2000]]

      case :ssh_agent.user_key(algorithm, agent_opts) do
        {:ok, {:ssh2_pubkey, _blob}} = res ->
          Logger.info(
            "SSH KeyCallback: found matching key in SSH Agent for #{inspect(algorithm)}"
          )

          res

        other ->
          other
      end
    catch
      kind, reason ->
        Logger.debug("SSH KeyCallback: query to SSH Agent failed: #{inspect({kind, reason})}")
        {:error, :enoent}
    end
  end

  defp get_identity_file(options) do
    case Keyword.get(options, :key_cb_private) do
      nested when is_list(nested) ->
        Keyword.get(nested, :identity_file) || Keyword.get(nested, :key_cb_private)

      path when is_binary(path) or is_list(path) ->
        path

      _ ->
        nil
    end
  end

  defp get_agent_socket(options) do
    case Keyword.get(options, :key_cb_private) do
      nested when is_list(nested) ->
        Keyword.get(nested, :agent_socket)

      _ ->
        nil
    end
  end

  def invalidate_key_cache(identity_file) do
    :persistent_term.erase({:caudata_key, identity_file})
  end

  defp decode_private_key(identity_file) do
    case :persistent_term.get({:caudata_key, identity_file}, nil) do
      {:ok, key} ->
        {:ok, key}

      _ ->
        result = do_decode_private_key(identity_file)

        case result do
          {:ok, key} ->
            :persistent_term.put({:caudata_key, identity_file}, {:ok, key})
            {:ok, key}

          other ->
            :persistent_term.erase({:caudata_key, identity_file})
            other
        end
    end
  end

  defp do_decode_private_key(identity_file) do
    case File.read(identity_file) do
      {:ok, pem_binary} ->
        try do
          decode_pem(pem_binary, identity_file)
        rescue
          e ->
            Logger.info(
              "SSH KeyCallback: Failed to decode key in #{identity_file}: #{inspect(e)}"
            )

            {:error, "Failed to decode key: #{inspect(e)}"}
        end

      {:error, reason} ->
        Logger.info(
          "SSH KeyCallback: Failed to read identity file #{identity_file}: #{inspect(reason)}"
        )

        {:error, "Failed to read identity file: #{inspect(reason)}"}
    end
  end

  defp decode_pem(pem_binary, identity_file) do
    case :public_key.pem_decode(pem_binary) do
      [entry | _] = entries ->
        Logger.info("SSH KeyCallback: found #{length(entries)} PEM entries in #{identity_file}")

        decode_entry(entry, pem_binary)

      _ ->
        Logger.info("SSH KeyCallback: No PEM entries found in #{identity_file}")
        {:error, "No PEM entries found"}
    end
  end

  # OpenSSH format keys (ed25519, etc.) produce a {:no_asn1, _} tag
  defp decode_entry({{:no_asn1, _}, _data, _cipher}, pem_binary) do
    case :ssh_file.decode(pem_binary, :public_key) do
      [{private_key, _attributes} | _rest] ->
        Logger.info("SSH KeyCallback: successfully decoded private key using :ssh_file.decode/2")

        {:ok, private_key}

      other ->
        Logger.info("SSH KeyCallback: failed to decode OpenSSH key: #{inspect(other)}")
        {:error, "Failed to decode OpenSSH key"}
    end
  end

  # Standard PEM format keys (RSA, ECDSA, etc.)
  defp decode_entry(entry, _pem_binary) do
    private_key = :public_key.pem_entry_decode(entry)

    Logger.info(
      "SSH KeyCallback: successfully decoded private key of type #{inspect(elem(private_key, 0))}"
    )

    {:ok, private_key}
  end

  defp sign_algorithm({:ECPrivateKey, _, _, _, _}), do: :ecdsa
  defp sign_algorithm({:ed_pri, :ed25519, _, _}), do: :eddsa
  defp sign_algorithm({:ed_pri, :ed448, _, _}), do: :eddsa
  defp sign_algorithm(_rsa_or_dsa), do: :sha256
end
