defmodule Caudata.Web.Endpoint do
  use Phoenix.Endpoint, otp_app: :caudata

  @session_options [
    store: :cookie,
    key: "_caudata_key",
    signing_salt: "CaudataSessionSigningSalt"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/",
    from: :caudata,
    gzip: false,
    only: ~w(assets favicon.ico robots.txt)
  )

  # Code reloading can be enabled in development
  if code_reloading? do
    plug(Phoenix.CodeReloader)
  end

  plug(Plug.RequestId)
  plug(Plug.Telemetry, event_prefix: [:phoenix, :endpoint])

  plug(Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()
  )

  plug(Plug.MethodOverride)
  plug(Plug.Head)
  plug(Plug.Session, @session_options)
  plug(Caudata.Web.Router)
end
