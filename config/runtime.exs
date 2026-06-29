import Config

# Acknowledge that tailscale-rs is experimental software as required by the library.
# This must be set before the NIF is loaded or used.
System.put_env("TS_RS_EXPERIMENT", "this_is_unstable_software")

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration here, only runtime.

if System.get_env("PHX_SERVER") in ["true", "1"] || config_env() in [:dev, :test] do
  config :caudata, Caudata.Web.Endpoint, server: true
else
  config :caudata, Caudata.Web.Endpoint, server: false
end

# Resolve port
port =
  case System.get_env("PORT") do
    nil -> if config_env() == :test, do: 4002, else: 4000
    val -> String.to_integer(val)
  end

# Resolve host/ip to bind
ip_str = System.get_env("CAUDATA_IP") || "127.0.0.1"

ip =
  case ip_str do
    "any" ->
      {0, 0, 0, 0}

    "0.0.0.0" ->
      {0, 0, 0, 0}

    _ ->
      ip_str
      |> String.split(".")
      |> Enum.map(&String.to_integer/1)
      |> List.to_tuple()
  end

# Secret key base
secret_key_base =
  System.get_env("RELEASE_COOKIE") ||
    System.get_env("SECRET_KEY_BASE") ||
    String.duplicate("secret_key_base_secure_salt_caudata_streamer", 2)

config :caudata, Caudata.Web.Endpoint,
  http: [ip: ip, port: port],
  pubsub_server: Caudata.PubSub,
  secret_key_base: secret_key_base,
  live_view: [signing_salt: "SigningSaltForCaudataLiveViewSecuritySalt"],
  render_errors: [formats: [html: Caudata.Web.ErrorHTML], layout: false]
