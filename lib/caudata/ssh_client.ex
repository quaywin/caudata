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

    @channel_timeout 5_000

    @impl true
    def connect(host, port, opts) do
      user = Keyword.get(opts, :user)

      if is_nil(user) or user == "" do
        {:error, :missing_user}
      else
        do_connect(host, port, user, opts)
      end
    end

    defp do_connect(host, port, user, opts) do
      char_host = to_charlist(host)
      identity_file = Keyword.get(opts, :identity_file)

      # Build standard options
      # silently_accept_hosts: true — this is an internal tool, host key verification
      # is handled by KeyCallback.is_host_key/5 when a custom key_cb is set.
      ssh_opts = [
        user: to_charlist(user),
        silently_accept_hosts: true,
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
    end

    @impl true
    def exec(conn_ref, channel_id, command) do
      case :ssh_connection.exec(conn_ref, channel_id, to_charlist(command), @channel_timeout) do
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
      # Send EOF first to signal no more input — this causes the remote process
      # to receive SIGPIPE on its next stdout/stderr write and exit cleanly.
      # Without this, long-running commands (docker logs --follow, tail -F, etc.)
      # may survive a bare channel close on some SSH servers.
      _ = :ssh_connection.send_eof(conn_ref, channel_id)
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
  def sign(key, data, _options) do
    algorithm = sign_algorithm(key)
    :public_key.sign(data, algorithm, key)
  end

  @impl true
  def user_key(algorithm, options) do
    Logger.debug(
      "SSH KeyCallback: user_key requested for algorithm #{inspect(algorithm)} with options: #{inspect(options)}"
    )

    # Erlang SSH wraps :key_cb options in an extra layer, so we unwrap twice:
    #   options[:key_cb_private][:key_cb_private] -> identity_file path
    case get_identity_file(options) do
      identity_file when is_binary(identity_file) ->
        decode_private_key(identity_file)

      _ ->
        Logger.debug("SSH KeyCallback: No identity file specified in options")
        {:error, "No identity file specified"}
    end
  end

  # -- Private helpers --

  defp get_identity_file(options) do
    options
    |> Keyword.get(:key_cb_private, [])
    |> then(fn
      nested when is_list(nested) -> Keyword.get(nested, :key_cb_private)
      _ -> nil
    end)
  end

  defp decode_private_key(identity_file) do
    case File.read(identity_file) do
      {:ok, pem_binary} ->
        try do
          decode_pem(pem_binary, identity_file)
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
  end

  defp decode_pem(pem_binary, identity_file) do
    case :public_key.pem_decode(pem_binary) do
      [entry | _] = entries ->
        Logger.debug("SSH KeyCallback: found #{length(entries)} PEM entries in #{identity_file}")

        decode_entry(entry, pem_binary)

      _ ->
        Logger.debug("SSH KeyCallback: No PEM entries found in #{identity_file}")
        {:error, "No PEM entries found"}
    end
  end

  # OpenSSH format keys (ed25519, etc.) produce a {:no_asn1, _} tag
  defp decode_entry({{:no_asn1, _}, _data, _cipher}, pem_binary) do
    case :ssh_file.decode(pem_binary, :public_key) do
      [{private_key, _attributes} | _rest] ->
        Logger.debug("SSH KeyCallback: successfully decoded private key using :ssh_file.decode/2")

        {:ok, private_key}

      other ->
        Logger.debug("SSH KeyCallback: failed to decode OpenSSH key: #{inspect(other)}")
        {:error, "Failed to decode OpenSSH key"}
    end
  end

  # Standard PEM format keys (RSA, ECDSA, etc.)
  defp decode_entry(entry, _pem_binary) do
    private_key = :public_key.pem_entry_decode(entry)

    Logger.debug(
      "SSH KeyCallback: successfully decoded private key of type #{inspect(elem(private_key, 0))}"
    )

    {:ok, private_key}
  end

  defp sign_algorithm({:ECPrivateKey, _, _, _, _}), do: :ecdsa
  defp sign_algorithm({:ed_pri, :ed25519, _, _}), do: :eddsa
  defp sign_algorithm({:ed_pri, :ed448, _, _}), do: :eddsa
  defp sign_algorithm(_rsa_or_dsa), do: :sha256
end
