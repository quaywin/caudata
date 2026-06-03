import Config

config :logger, level: :info

if Mix.env() == :test do
  System.put_env("CAUDATA_SSH_CONFIG_PATH", "test/fixtures/mock_ssh_config")
end
