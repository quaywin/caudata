defmodule Caudata.Web.LogLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint Caudata.Web.Endpoint

  setup do
    # Terminate the default global ConfigManager to isolate the test and free up the name
    _ = Supervisor.terminate_child(Caudata.Supervisor, Caudata.ConfigManager)

    # Create a temporary mock SSH config
    temp_dir = System.tmp_dir!()

    temp_path =
      Path.join(temp_dir, "mock_ssh_config_" <> to_string(System.unique_integer([:positive])))

    File.write!(temp_path, """
    Host aws-contrypt-api
      HostName ec2-18-162-211-161.ap-east-1.compute.amazonaws.com
      User ec2-user
      Port 22
      IdentityFile ~/.ssh/aws-contrypt-prod.pem
      LocalForward 2222 127.0.0.1:22
    """)

    config_path = System.get_env("CAUDATA_CONFIG_PATH") || "test/fixtures/test_suite_config.db"
    File.mkdir_p!(Path.dirname(config_path))
    File.rm_rf(config_path)

    :ok =
      Caudata.Config.append_profile(%{
        id: "aws-contrypt-api",
        host_pattern: "aws-contrypt-api",
        host_name: "ec2-18-162-211-161.ap-east-1.compute.amazonaws.com",
        port: 22
      })

    # Start a test-supervised ConfigManager with the mock config
    {:ok, _pid} =
      start_supervised(
        {Caudata.ConfigManager, name: Caudata.ConfigManager, ssh_config_path: temp_path}
      )

    # Restart the global ConfigManager on exit
    on_exit(fn ->
      File.rm_rf(config_path)
      _ = Supervisor.restart_child(Caudata.Supervisor, Caudata.ConfigManager)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  test "mounts the LiveView and renders layout successfully", %{conn: conn} do
    {:ok, view, html} = live(conn, "/")
    assert html =~ "phoenix-ex-ratatui"

    # Send the resize event to boot the transport session
    render_hook(view, "phx_ex_ratatui:resize", %{"cols" => 80, "rows" => 24})

    # Assert that a render update was pushed to the client
    assert_push_event(view, "phx_ex_ratatui:render", payload, 1000)

    # Reconstruct the grid text from the payload ops
    grid_text =
      payload["ops"]
      |> Enum.group_by(fn [row | _] -> row end)
      |> Enum.sort_by(fn {row, _} -> row end)
      |> Enum.map(fn {_row, cell_ops} ->
        cell_ops
        |> Enum.sort_by(fn [_, col | _] -> col end)
        |> Enum.map(fn [_, _, sym | _] -> sym end)
        |> Enum.join("")
      end)
      |> Enum.join("\n")

    case Caudata.ConfigManager.list_profiles() do
      [first | _] ->
        assert grid_text =~ first.id

      _ ->
        :ok
    end

    assert grid_text =~ "No container selected"
  end

  test "renders 404 for invalid routes without crashing", %{conn: conn} do
    conn = get(conn, "/invalid-path")
    assert conn.status == 404
    assert conn.resp_body =~ "Not Found"
  end
end
