# Caudata 🌯

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Caudata** is a collaborative, zero-config multi-server log streamer built with **Elixir/OTP**, **Ratatui (TUI)**, and **Phoenix LiveView**. 

It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, without installing any agents on remote hosts. The system utilizes supervised OTP processes, bounded per-source ring buffers, and renders a single interactive application across multiple targets (CLI/TUI and Web Browser).

---

## 🚀 Features

- **Docker Container Auto-Discovery**: Automatically runs `docker ps` upon connection to discover running Docker containers on the remote host and displays them in a tree structure.
- **Granular Log Streaming**: Stream logs from specific Docker containers (using `docker logs --follow`), or fallback to the system log command (e.g. `tail -F /var/log/messages`) if Docker is not available.
- **Multi-Server Aggregation**: Automatically discovers SSH connections in `~/.ssh/config` and streams logs using Erlang's native `:ssh` and `:ssh_connection` (no external `ssh` binary required).
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

### Sidebar Navigation
- `↑` / `↓`: Move selection between remote servers and their discovered Docker containers.
- `Enter` (when selecting a server): Force-refresh the Docker container list on that remote host.
- `a` / `A`: Open the connection popup to discover servers from `~/.ssh/config` or type manual settings.

### Logs Pane
- `j`: Scroll logs down by 3 lines.
- `k`: Scroll logs up by 3 lines (scrolling to the top automatically fetches older logs from the history buffer; it will restart SSH streaming with a larger tail limit up to 5000 lines if necessary).
- `/`: Enter search mode to filter logs in real-time using regular expressions (Regex).
- `Enter` (in search mode): Keep the active filter and return to normal mode.
- `Esc` / `Escape`: Clear active regex filter or exit popup modals.
- `q` / `Q`: Exit Caudata.

---

## ⚙️ Configuration

Caudata looks for a configuration file at `~/.caudata/config.toml`. If it doesn't exist, a default config will be created automatically on the first boot.

### Config File Format

Here is an example `config.toml` structure:

```toml
[global]
# Bounded queue capacity for logs (default: 1000 lines per server)
capacity = 1000

# Default command to run on remote servers to stream logs (used as fallback)
log_command = "tail -F /var/log/messages"

# Whether to auto-discover connection profiles from ~/.ssh/config (default: true)
discover_ssh_config = true

# Manually define remote server connection profiles (optional)
[[profiles]]
id = "web-prod-1"
host_name = "192.168.1.50"
port = 22
user = "deploy"
identity_file = "~/.ssh/id_rsa"
log_command = "tail -F /var/log/nginx/access.log"

[[profiles]]
id = "database-replica"
host_name = "db-replica.internal"
port = 2222
user = "postgres"
identity_file = "~/.ssh/id_ed25519"
```

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
