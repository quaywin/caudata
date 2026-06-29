import Config

# Acknowledge that tailscale-rs is experimental software as required by the library.
# This must be set before the NIF is loaded or used.
System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")

config :caudata, :env, Mix.env()

config :logger, level: :info

if Mix.env() == :test do
  System.put_env("CAUDATA_SSH_CONFIG_PATH", "test/fixtures/mock_ssh_config")
  config :caudata, :log_debounce_delay, 0
  config :caudata, :stats_debounce_delay, 0
end

if Mix.env() == :dev do
  config :caudata, Caudata.Web.Endpoint,
    code_reloader: true,
    live_reload: [
      patterns: [
        ~r"lib/caudata/.*(ex)$"
      ]
    ]
end
