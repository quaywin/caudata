# Caudata 🌯

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Caudata** is a collaborative, zero-config multi-server log streamer built with **Elixir/OTP**, **Ratatui (TUI)**, and **Phoenix LiveView**. 

It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, without installing any agents on remote hosts. The system utilizes supervised OTP processes, bounded per-source ring buffers, and renders a single interactive application across multiple targets (CLI/TUI and Web Browser).

---

## 🚀 Features

- **Docker Container Auto-Discovery**: Automatically runs `docker ps` upon connection to discover running Docker containers on the remote host and displays them in a tree structure.
- **Granular Log Streaming**: Stream logs from specific Docker containers (using `docker logs --follow`) or custom file paths (marked with `📄` next to the whale `🐳` icon) using native tail commands.
- **Custom File Log Streaming**: Register arbitrary remote log files (e.g., `/var/log/nginx/error.log`) with built-in remote readability checks `[ -r path ]` executed via SSH.
- **Multi-Server Aggregation**: Automatically discovers SSH connections in `~/.ssh/config` and streams logs using Erlang's native `:ssh` and `:ssh_connection` (no external `ssh` binary required).
- **Tabbed Settings Modal**: Manage server states (enable, disable, or delete profiles), selectively toggle container logging visibility, and add/remove custom log paths.
- **Reactive UI & Configuration Store**: Configuration is backed by a zero-latency concurrent ETS table storage. Changes to connection profiles, enabled/disabled servers, or filters instantly hot-swap their corresponding supervisor worker processes.
- **Multiple Rendering Targets**:
  - **Local Terminal UI (TUI)**: Fully interactive TUI in your command line.
  - **Web Mirror (Phoenix LiveView)**: Mirrors the interactive terminal directly to your web browser with a bounded DOM viewport using `PhoenixExRatatui`.
- **Resilient & Safe**: Bounded ring buffers (1000 lines per source by default) with drop accounting and process-isolated workers. Invalid filter regexes are safely caught without crashing.
- **Single-Binary Packaging**: Self-extracting executables containing the entire application and the Erlang runtime (no dependency on Elixir/Erlang on the host machine).

---

## 📦 Installation

### Option 1: Quick Install (Recommended)

You can download and install the latest pre-compiled single binary of Caudata directly using the following command:

```bash
curl -fsSL https://raw.githubusercontent.com/quaywin/caudata/main/install.sh | sh
```

This installer script will:
1. Detect your Operating System (macOS or Linux) and CPU architecture (`x86_64` or `aarch64`).
2. Download the appropriate Burrito single-binary release from GitHub.
3. Install the executable to `/usr/local/bin` (or fall back to `~/.local/bin` if permissions are restricted).
4. Make it executable (`chmod +x`).

### Option 2: Running from Source (Development)

To run Caudata using the Elixir source code, make sure you have [mise](https://mise.jdx.dev/) installed.

```bash
# Clone the repository
git clone https://github.com/quaywin/caudata.git
cd caudata

# Install correct toolchains (Elixir, Erlang, Zig) via mise
mise install

# Fetch Elixir dependencies
mise exec -- mix deps.get

# Run Caudata in development mode
mise exec -- mix run --no-halt
```

Once started:
- The TUI will boot directly in your terminal.
- Access the web UI mirror at [http://localhost:4000](http://localhost:4000).

---

## 🛠️ Keybindings (TUI Control)

When running Caudata's Terminal UI, use the following keybindings to interact with the application:

### Normal Mode (Sidebar & Logs Navigation)
- `↑` / `↓` or `k` / `j`: Move selection in the sidebar directly between active containers (`🐳`) and custom logs (`📄`) (automatically skips server header titles).
- `Enter` (in sidebar): Connect to the selected target and start streaming its logs.
- `a` / `A` / `+`: Open the **Add SSH Connection** modal.
- `s` / `S`: Open the **Global Settings** modal.
- `/`: Enter search mode to filter logs in real-time using regular expressions (Regex).
- `Enter` (in search mode): Apply the active filter and return to navigation mode.
- `Esc` / `Escape`: Clear active search filter or close open modals.
- `q` / `Q`: Exit Caudata.

### Add SSH Connection Modal
- **SSH Config List Selection**:
  - `↑` / `↓` or `k` / `j`: Navigate through discovered SSH profiles.
  - `Enter`: Select profile or choose manual configuration.
- **Manual Input Form**:
  - `↑` / `↓`: Cycle focus through form fields (Connection Name, Host, Port, User, SSH Key, custom Log Command) and action buttons (Save, Cancel).
  - `Enter`: Confirm action / submit form.
  - `Esc`: Return to profile list selection.

### Settings Modal
- **Tab Switching**: Press `Tab` or `←` / `→` or `h` / `l` to cycle through tabs:
  - **Servers**: Configure active profiles, view connection status (`● connected`, `◌ connecting`, `○ disconnected`, or `⊘ disabled`), or toggle/delete servers.
  - **Docker Containers**: Toggle visibility of individual discovered Docker containers.
  - **Custom Logs**: Register, toggle, or delete arbitrary log paths.
- **Navigation & Selection**:
  - `↑` / `↓` or `k` / `j`: Scroll through the list items in the active tab.
  - `Space`: Toggle the selected item (Enable/disable server, show/hide container, enable/disable custom log).
  - `a` / `A` (in *Custom Logs* tab): Open a path input box to add a custom log file (automatically runs an SSH remote readability test `[ -r path ]` before saving).
  - `d` / `D` or `Backspace` (in *Servers* or *Custom Logs* tabs): Delete the selected server connection or custom log path.
  - `Esc`: Close settings modal.

---

## ⚙️ Configuration

Caudata automatically manages your configuration inside `~/.caudata/config.db`. This binary database uses Erlang Term Storage (ETS) to ensure zero-latency reads while executing asynchronously saved updates.

Instead of manually editing configuration files, you can manage your connections and options directly inside the application using the **Add SSH Connection** (`a`) and **Settings** (`s`) modals.

### Custom Log Tail Limit
The log view is backed by bounded ring buffers. By default, it stores the last `1000` lines per stream source to prevent high memory consumption.

### Environment Variables

You can configure the HTTP Web interface:

- `PORT`: HTTP port for Phoenix Web mirror (default: `4000` in prod/dev, `4002` in test).
- `CAUDATA_IP`: Bind address for the Web server (default: `127.0.0.1`, set to `any` or `0.0.0.0` to allow external connections).
- `SECRET_KEY_BASE`: Phoenix Session security key (optional, automatically generated if not supplied).

---

## 🗺️ Roadmap / Planned Features

- **Collaborative SSH UI Server**: Connect to Caudata securely over SSH to participate in a shared multiplexed terminal session.
- **Log Archiving**: Export stream buffers to local files or remote S3-compatible object storage.
- **Advanced Alerts**: Trigger webhooks or notifications when specific log patterns are matched.

---

## 🏗️ Building Releases Locally

If you want to package Caudata into a single-binary using Burrito yourself:

```bash
# 1. Install toolchains (make sure zig is installed via mise)
mise install

# 2. Build for a specific target (e.g. macOS Apple Silicon)
BURRITO_TARGET=macos_aarch64 mise exec -- mix release --overwrite

# 3. Available targets defined in mix.exs:
#    - macos_aarch64 (macOS Apple Silicon)
#    - macos_x86_64  (macOS Intel)
#    - linux_x86_64  (Linux Intel/AMD)
```

The output executables will be compiled and saved to `burrito_out/`.

---

## 🧪 Testing

Run the full Elixir unit test suite:

```bash
mise exec -- mix test
```

## 🤝 Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for details on how to get started and our [Code of Conduct](CODE_OF_CONDUCT.md).

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
