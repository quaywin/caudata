defmodule Caudata.UI.Components.ContainerInspectModal do
  @moduledoc """
  Renders popup modal displaying filtered, essential container inspection details (Overview, Ports, Mounts, Envs, Limits),
  with an option to toggle raw JSON view, designed for maximum visual clarity and TUI aesthetics.
  """
  alias ExRatatui.Style
  alias ExRatatui.Text.Line
  alias ExRatatui.Text.Span
  alias ExRatatui.Widgets.Block
  alias ExRatatui.Widgets.Paragraph
  alias ExRatatui.Widgets.Popup

  def render(state) do
    container_name = Map.get(state, :selected_container_name, "Container")
    inspect_raw = Map.get(state, :container_inspect_data, "Loading inspect details...")
    scroll_y = Map.get(state, :container_inspect_scroll_y, 0)
    mode = Map.get(state, :container_inspect_mode, :summary)

    parsed_json =
      case Jason.decode(inspect_raw) do
        {:ok, p} -> p
        _ -> nil
      end

    selected_profile = Enum.find(Map.get(state, :profiles, []), &(&1.id == Map.get(state, :selected_profile_id)))
    server_host = (selected_profile && selected_profile.host_name) || ""

    summary = if parsed_json, do: extract_summary(parsed_json, server_host), else: nil
    is_running = (summary && summary.running) || false

    formatted_lines = format_inspect_data(inspect_raw, mode, summary)
    total_lines = length(formatted_lines)
    visible_lines = Enum.drop(formatted_lines, scroll_y)

    badge_status =
      if is_running do
        Span.new(" [ 🟢 RUNNING ] ", style: %Style{fg: :black, bg: :green, modifiers: [:bold]})
      else
        Span.new(" [ 🔴 EXITED ] ", style: %Style{fg: :white, bg: :red, modifiers: [:bold]})
      end

    mode_badge =
      if mode == :summary do
        Span.new(" [ 📄 SUMMARY ] ", style: %Style{fg: :black, bg: :cyan, modifiers: [:bold]})
      else
        Span.new(" [ 📜 RAW JSON ] ", style: %Style{fg: :black, bg: :magenta, modifiers: [:bold]})
      end

    popup_inner_width = max(10, div(Map.get(state, :width, 80) * 85, 100) - 4)

    header_lines = [
      Line.new([
        Span.new(" Container: ", style: %Style{fg: :dark_gray}),
        Span.new(to_string(container_name), style: %Style{fg: :yellow, modifiers: [:bold]}),
        Span.new("  "),
        badge_status,
        Span.new(" "),
        mode_badge,
        Span.new("  Line #{scroll_y + 1}/#{total_lines}", style: %Style{fg: :dark_gray})
      ]),
      Line.new([
        Span.new(String.duplicate("─", popup_inner_width), style: %Style{fg: :dark_gray})
      ])
    ]

    popup_widget = %Popup{
      content: %Paragraph{
        text: header_lines ++ visible_lines
      },
      block: %Block{
        title: " ℹ️ Docker Inspect ",
        borders: [:all],
        border_type: :rounded
      },
      percent_width: 85,
      percent_height: 80
    }

    [popup_widget]
  end

  def handle_key(key, key_data, model) do
    norm_key = if key == :char, do: Map.get(key_data, :char), else: key
    scroll_y = Map.get(model, :container_inspect_scroll_y, 0)
    mode = Map.get(model, :container_inspect_mode, :summary)
    inspect_raw = Map.get(model, :container_inspect_data, "")

    parsed_json =
      case Jason.decode(inspect_raw) do
        {:ok, p} -> p
        _ -> nil
      end

    selected_profile = Enum.find(Map.get(model, :profiles, []), &(&1.id == Map.get(model, :selected_profile_id)))
    server_host = (selected_profile && selected_profile.host_name) || ""

    summary = if parsed_json, do: extract_summary(parsed_json, server_host), else: nil
    total_lines = length(format_inspect_data(inspect_raw, mode, summary))
    inner_height = max(1, div(Map.get(model, :height, 24) * 80, 100) - 4)
    max_scroll = max(0, total_lines - inner_height)

    case norm_key do
      k when k in [:up, "k", "K"] ->
        new_scroll = max(0, scroll_y - 1)
        {Map.put(model, :container_inspect_scroll_y, new_scroll), []}

      k when k in [:down, "j", "J"] ->
        new_scroll = min(max_scroll, scroll_y + 1)
        {Map.put(model, :container_inspect_scroll_y, new_scroll), []}

      k when k in [:home, "g"] ->
        {Map.put(model, :container_inspect_scroll_y, 0), []}

      k when k in [:end, "G"] ->
        {Map.put(model, :container_inspect_scroll_y, max_scroll), []}

      k when k in [:page_down, :pagedown] ->
        new_scroll = min(max_scroll, scroll_y + inner_height)
        {Map.put(model, :container_inspect_scroll_y, new_scroll), []}

      k when k in [:page_up, :pageup] ->
        new_scroll = max(0, scroll_y - inner_height)
        {Map.put(model, :container_inspect_scroll_y, new_scroll), []}

      k when k in ["r", "R"] ->
        new_mode = if mode == :summary, do: :raw, else: :summary

        new_model =
          model
          |> Map.put(:container_inspect_mode, new_mode)
          |> Map.put(:container_inspect_scroll_y, 0)

        {new_model, []}

      k when k in [:escape, :esc, "q", "Q"] ->
        {%{model | modal_visible: false}, []}

      _ ->
        {model, []}
    end
  end

  def format_inspect_data(raw_str, mode) do
    parsed_json =
      case Jason.decode(raw_str) do
        {:ok, p} -> p
        _ -> nil
      end

    summary = if parsed_json, do: extract_summary(parsed_json), else: nil
    format_inspect_data(raw_str, mode, summary)
  end

  def format_inspect_data(raw_str, mode, summary) when is_binary(raw_str) do
    if mode == :raw do
      case Jason.decode(raw_str) do
        {:ok, parsed} -> format_raw_json(parsed)
        _ -> raw_text_lines(raw_str)
      end
    else
      if summary do
        format_summary_lines(summary)
      else
        raw_text_lines(raw_str)
      end
    end
  end

  def format_inspect_data(_, _mode, _summary),
    do: [Line.new([Span.new("No inspect data available", style: %Style{fg: :red})])]

  defp raw_text_lines(raw_str) do
    String.split(raw_str, "\n")
    |> Enum.map(fn line -> Line.new([Span.new(line, style: %Style{fg: :white})]) end)
  end

  def extract_summary(parsed, server_host \\ "") do
    item =
      case parsed do
        [first | _] when is_map(first) -> first
        map when is_map(map) -> map
        _ -> %{}
      end

    full_id = Map.get(item, "Id", "")
    id = String.slice(full_id, 0..11)
    name = Map.get(item, "Name", "") |> String.trim_leading("/")
    created = Map.get(item, "Created", "") |> format_time()

    config = Map.get(item, "Config", %{}) || %{}
    image = Map.get(config, "Image", "") || Map.get(item, "Image", "")
    working_dir = Map.get(config, "WorkingDir", "")

    entrypoint = Map.get(config, "Entrypoint") || []
    cmd = Map.get(config, "Cmd") || []
    full_cmd = (entrypoint ++ cmd) |> Enum.join(" ")

    state = Map.get(item, "State", %{}) || %{}
    status_str = Map.get(state, "Status", "")
    running = Map.get(state, "Running", false)
    exit_code = Map.get(state, "ExitCode", 0)

    network_settings = Map.get(item, "NetworkSettings", %{}) || %{}
    host_config = Map.get(item, "HostConfig", %{}) || %{}
    root_ip = Map.get(network_settings, "IPAddress", "")
    networks_map = Map.get(network_settings, "Networks", %{}) || %{}
    networks = Map.keys(networks_map) |> Enum.join(", ")

    network_ips =
      Enum.map(networks_map, fn {net_name, net_config} ->
        ip = Map.get(net_config || %{}, "IPAddress", "")
        if is_binary(ip) and ip != "", do: "#{ip} (#{net_name})", else: nil
      end)
      |> Enum.reject(&is_nil/1)

    ip_address =
      cond do
        network_ips != [] ->
          Enum.join(network_ips, ", ")

        is_binary(root_ip) and root_ip != "" ->
          root_ip

        not running ->
          "N/A (Container Exited)"

        Map.get(host_config, "NetworkMode", "") == "host" ->
          if is_binary(server_host) and server_host != "",
            do: "#{server_host} (Host Network)",
            else: "Host Network Mode"

        true ->
          "N/A"
      end

    # Extract Ports mapping
    ports_map = Map.get(network_settings, "Ports", %{}) || %{}
    host_port_bindings = Map.get(host_config, "PortBindings", %{}) || %{}
    exposed_ports_map = Map.get(config, "ExposedPorts", %{}) || %{}

    all_ports_map = Map.merge(exposed_ports_map, Map.merge(host_port_bindings, ports_map))
    is_host_net = Map.get(host_config, "NetworkMode", "") == "host"

    port_tuples =
      cond do
        all_ports_map != %{} ->
          Enum.flat_map(all_ports_map, fn {container_port, bindings} ->
            cond do
              is_list(bindings) and bindings != [] ->
                Enum.map(bindings, fn b ->
                  host_ip = Map.get(b, "HostIp", "0.0.0.0")
                  host_port = Map.get(b, "HostPort", "")
                  {container_port, host_ip, host_port}
                end)

              is_host_net ->
                port_num =
                  case String.split(to_string(container_port), "/") do
                    [p | _] -> p
                    _ -> to_string(container_port)
                  end

                [{container_port, "Direct Host", "#{port_num}"}]

              true ->
                [{container_port, nil, nil}]
            end
          end)

        is_host_net ->
          [{"Host Network Stack", "Direct Host", "Direct on Host"}]

        true ->
          []
      end

    # Extract Mounts
    mounts = Map.get(item, "Mounts", []) || []

    # Extract ENV
    envs = Map.get(config, "Env", []) || []

    # Extract HostConfig limits & restart policy
    host_config = Map.get(item, "HostConfig", %{}) || %{}
    restart_policy = Map.get(host_config, "RestartPolicy", %{}) |> Map.get("Name", "no")
    mem_limit_bytes = Map.get(host_config, "Memory", 0)

    mem_limit =
      if is_integer(mem_limit_bytes) and mem_limit_bytes > 0 do
        "#{div(mem_limit_bytes, 1024 * 1024)} MB"
      else
        "Unlimited"
      end

    %{
      id: id,
      full_id: full_id,
      name: name,
      image: image,
      created: created,
      working_dir: working_dir,
      cmd: full_cmd,
      status: status_str,
      running: running,
      exit_code: exit_code,
      ip_address: ip_address,
      networks: networks,
      port_tuples: port_tuples,
      mounts: mounts,
      envs: envs,
      restart_policy: restart_policy,
      mem_limit: mem_limit
    }
  end

  defp format_summary_lines(s) do
    status_color = if s.running, do: :green, else: :red
    status_text = if s.running, do: "Up / Running", else: "Exited (Exit Code: #{s.exit_code})"

    overview_lines = [
      header_section("📌  BASIC OVERVIEW"),
      kv_line("Name:", s.name, :yellow, [:bold]),
      kv_line("ID:", "#{s.id} (#{s.full_id})", :white, []),
      kv_line("Image:", s.image, :cyan, []),
      kv_line("Status:", status_text, status_color, [:bold]),
      kv_line("Created:", s.created, :dark_gray, [])
    ]

    cmd_lines =
      if s.cmd != "" do
        [kv_line("Command:", s.cmd, :white, [])]
      else
        []
      end

    workdir_lines =
      if s.working_dir != "" do
        [kv_line("WorkDir:", s.working_dir, :dark_gray, [])]
      else
        []
      end

    overview = overview_lines ++ cmd_lines ++ workdir_lines ++ [Line.new([])]

    # Networks & Ports
    network_lines = [
      header_section("🔌  NETWORKS & PORTS"),
      kv_line("IP Address:", if(s.ip_address != "", do: s.ip_address, else: "N/A"), :green, []),
      kv_line("Networks:", if(s.networks != "", do: s.networks, else: "default"), :cyan, [])
    ]

    port_lines =
      if s.port_tuples != [] do
        Enum.map(s.port_tuples, fn
          {c_port, nil, nil} ->
            Line.new([
              Span.new("  🔌 ", style: %Style{fg: :yellow}),
              Span.new(to_string(c_port), style: %Style{fg: :cyan, modifiers: [:bold]}),
              Span.new(" (unmapped internal port)", style: %Style{fg: :dark_gray})
            ])

          {c_port, "Direct Host", hint} ->
            Line.new([
              Span.new("  🔌 ", style: %Style{fg: :yellow}),
              Span.new(to_string(c_port), style: %Style{fg: :cyan, modifiers: [:bold]}),
              Span.new(" ➔ ", style: %Style{fg: :dark_gray}),
              Span.new("Host Direct Port (#{hint})", style: %Style{fg: :green})
            ])

          {c_port, host_ip, host_port} ->
            Line.new([
              Span.new("  🔌 ", style: %Style{fg: :yellow}),
              Span.new(to_string(c_port), style: %Style{fg: :cyan, modifiers: [:bold]}),
              Span.new(" ➔ ", style: %Style{fg: :dark_gray}),
              Span.new("#{host_ip}:#{host_port}", style: %Style{fg: :yellow})
            ])
        end)
      else
        [kv_line("Port Mappings:", "None (No exposed ports)", :dark_gray, [])]
      end

    networks_section = network_lines ++ port_lines ++ [Line.new([])]

    # Mounts
    mount_header = [header_section("📁  MOUNTS & VOLUMES")]

    mount_lines =
      if s.mounts != [] do
        Enum.map(s.mounts, fn m ->
          src = Map.get(m, "Source", "")
          dst = Map.get(m, "Destination", "")
          mode = Map.get(m, "Mode", "rw")
          mode_color = if String.contains?(mode, "rw"), do: :green, else: :yellow

          Line.new([
            Span.new("  📁 ", style: %Style{fg: :cyan}),
            Span.new(src, style: %Style{fg: :light_blue}),
            Span.new(" ➔ ", style: %Style{fg: :dark_gray}),
            Span.new(dst, style: %Style{fg: :white}),
            Span.new(" [#{mode}]", style: %Style{fg: mode_color})
          ])
        end)
      else
        [Line.new([Span.new("  No mounts attached", style: %Style{fg: :dark_gray})])]
      end

    mounts_section = mount_header ++ mount_lines ++ [Line.new([])]

    # Limits & Restart Policy
    limits_section = [
      header_section("⚙️   RESTART POLICY & LIMITS"),
      kv_line("Restart Policy:", s.restart_policy, :yellow, []),
      kv_line("Memory Limit:", s.mem_limit, :white, []),
      Line.new([])
    ]

    # Environment Variables
    env_header = [header_section("🔑  ENVIRONMENT VARIABLES (#{length(s.envs)})")]

    env_lines =
      if s.envs != [] do
        Enum.map(s.envs, fn env_str ->
          case String.split(env_str, "=", parts: 2) do
            [var_name, val] ->
              Line.new([
                safe_span("  • ", style: %Style{fg: :dark_gray}),
                safe_span(var_name, style: %Style{fg: :yellow, modifiers: [:bold]}),
                safe_span(" = ", style: %Style{fg: :dark_gray}),
                safe_span(val, style: %Style{fg: :white})
              ])

            _ ->
              Line.new([safe_span("  • #{env_str}", style: %Style{fg: :white})])
          end
        end)
      else
        [Line.new([safe_span("  No environment variables set", style: %Style{fg: :dark_gray})])]
      end

    overview ++ networks_section ++ mounts_section ++ limits_section ++ env_header ++ env_lines
  end

  defp header_section(title) do
    Line.new([
      safe_span("── ", style: %Style{fg: :dark_gray}),
      safe_span(title, style: %Style{fg: :cyan, modifiers: [:bold]}),
      safe_span(" " <> String.duplicate("─", 40), style: %Style{fg: :dark_gray})
    ])
  end

  defp kv_line(key, value, val_color, modifiers) do
    Line.new([
      safe_span("  #{String.pad_trailing(key, 16)}", style: %Style{fg: :dark_gray}),
      safe_span(to_string(value), style: %Style{fg: val_color, modifiers: modifiers})
    ])
  end

  defp format_raw_json(parsed) do
    formatted = Jason.encode!(parsed, pretty: true)

    String.split(formatted, "\n")
    |> Enum.map(fn line ->
      style =
        cond do
          String.contains?(line, "\":") -> %Style{fg: :cyan}
          String.contains?(line, "true") or String.contains?(line, "false") -> %Style{fg: :yellow}
          String.contains?(line, "running") -> %Style{fg: :green}
          String.contains?(line, "exited") -> %Style{fg: :red}
          true -> %Style{fg: :white}
        end

      Line.new([safe_span(line, style: style)])
    end)
  end

  defp safe_span(text, opts) do
    clean_text =
      to_string(text)
      |> String.replace("\r\n", "\\n")
      |> String.replace("\n", "\\n")

    Span.new(clean_text, opts)
  end

  defp format_time(ts) when is_binary(ts) do
    case String.split(ts, "T") do
      [date, time_part] ->
        time = String.slice(time_part, 0..7)
        "#{date} #{time}"

      _ ->
        ts
    end
  end

  defp format_time(_), do: ""
end
