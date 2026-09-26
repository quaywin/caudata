defmodule Caudata.SSHClient.KeyCallbackTest do
  use ExUnit.Case, async: true
  alias Caudata.SSHClient.KeyCallback

  setup do
    temp_dir = System.tmp_dir!()
    unique = System.unique_integer([:positive])
    temp_path = Path.join(temp_dir, "key_callback_test_#{unique}")

    on_exit(fn ->
      File.rm(temp_path)
      File.rm("#{temp_path}.pub")
    end)

    {:ok, temp_path: temp_path}
  end

  test "successfully decodes standard RSA PEM private key", %{temp_path: temp_path} do
    {_, 0} = System.cmd("ssh-keygen", ["-t", "rsa", "-m", "PEM", "-N", "", "-f", temp_path])

    options = [key_cb_private: [key_cb_private: temp_path]]
    assert {:ok, private_key} = KeyCallback.user_key(:"ssh-rsa", options)
    assert is_tuple(private_key)
    assert elem(private_key, 0) == :RSAPrivateKey
  end

  test "successfully decodes OpenSSH format ed25519 private key", %{temp_path: temp_path} do
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", temp_path])

    options = [key_cb_private: [key_cb_private: temp_path]]
    assert {:ok, private_key} = KeyCallback.user_key(:"ssh-ed25519", options)
    assert is_tuple(private_key)
    # The returned private key type can be :ECPrivateKey or other types depending on OTP version,
    # but it should decode successfully.
    assert elem(private_key, 0) in [:ECPrivateKey, :ed_pri]
  end

  test "returns error when file does not exist" do
    options = [key_cb_private: [key_cb_private: "/nonexistent/key/path"]]
    assert {:error, _reason} = KeyCallback.user_key(:"ssh-rsa", options)
  end

  test "returns error when options are invalid or missing" do
    assert {:error, "No identity file specified"} = KeyCallback.user_key(:"ssh-rsa", [])

    assert {:error, "No identity file specified"} =
             KeyCallback.user_key(:"ssh-rsa", key_cb_private: [key_cb_private: 123])
  end

  test "sign/3 signs data with decoded RSA private key", %{temp_path: temp_path} do
    {_, 0} = System.cmd("ssh-keygen", ["-t", "rsa", "-m", "PEM", "-N", "", "-f", temp_path])
    options = [key_cb_private: [identity_file: temp_path]]
    assert {:ok, private_key} = KeyCallback.user_key(:"ssh-rsa", options)

    signature = KeyCallback.sign(private_key, "sample_payload_data", options)
    assert is_binary(signature)
    assert byte_size(signature) > 0
  end

  test "sign/3 signs data with decoded ed25519 private key", %{temp_path: temp_path} do
    {_, 0} = System.cmd("ssh-keygen", ["-t", "ed25519", "-N", "", "-f", temp_path])
    options = [key_cb_private: [identity_file: temp_path]]
    assert {:ok, private_key} = KeyCallback.user_key(:"ssh-ed25519", options)

    signature = KeyCallback.sign(private_key, "sample_payload_data", options)
    assert is_binary(signature)
    assert byte_size(signature) > 0
  end

  test "sign/3 gracefully handles pubkey blob and tuple for agent, returning <<>> on failure" do
    dead_opts = [key_cb_private: [agent_socket: "/tmp/nonexistent_dead.sock"]]

    # Pubkey tuple format
    assert KeyCallback.sign({:ssh2_pubkey, <<1, 2, 3, 4>>}, "payload", dead_opts) == <<>>

    # Raw binary pubkey format (from Erlang OTP ssh_client_key_api)
    assert KeyCallback.sign(<<1, 2, 3, 4>>, "payload", dead_opts) == <<>>

    # Malformed key format
    assert KeyCallback.sign({:invalid_key_struct}, "payload", dead_opts) == <<>>
  end

  test "user_key/2 falls back to agent socket when identity file fails" do
    options = [
      key_cb_private: [
        identity_file: "/nonexistent/key.pem",
        agent_socket: "/tmp/nonexistent_agent.sock"
      ]
    ]

    assert {:error, :enoent} = KeyCallback.user_key(:"ssh-rsa", options)
  end

  test "host key callbacks" do
    assert KeyCallback.is_host_key(nil, nil, nil, nil, nil) == true
    assert KeyCallback.add_host_key(nil, nil, nil, nil) == :ok
  end
end
