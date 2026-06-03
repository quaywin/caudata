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

    assert {:error, "identity_file is not a binary"} =
             KeyCallback.user_key(:"ssh-rsa", key_cb_private: [key_cb_private: 123])
  end
end
