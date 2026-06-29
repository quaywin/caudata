# Caudata 🦎

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Caudata** is a zero-config multi-server log streamer built with **Elixir/OTP** and [**ex_ratatui**](https://github.com/mcass19/ex_ratatui) 🦎.

It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, as well as the **local machine**, **without installing any agents** on remote hosts.

*Tired of SSH-ing into 5 different servers just to tail Docker logs? Caudata brings them all (and your local setup) into a single, responsive terminal dashboard.*

---

## ⚡ Quick Demo

![Caudata TUI Demo](assets/demo.gif)

---

## 🚀 Key Features

- 🛡️ **Zero-Agent / Secure SSH**: Connects seamlessly using your existing `~/.ssh/config` or custom server configurations. Supports both **SSH key files (private keys)** and **password authentication** securely. No remote agents, no daemon installation, and no extra configuration needed on target servers.
- 💻 **Local Machine Monitoring**: Monitor containers and services on your local machine using direct port communication (bypassing SSH). Optionally specify your sudo password for commands requiring elevated privileges.
- 🐳 **Real-Time Docker Discovery & Recovery**: Auto-discovers running Docker containers. Automatically reconnects active log streams when a container is rebuilt or restarted.
- ⚙️ **System Services Support**: Stream logs from system daemon services running under **Systemd** (Linux) or **Launchd** (macOS).
- 📄 **Custom Log Paths**: Add and stream specific custom log paths from remote machines.
- 📊 **Real-time Server & Container Metrics**: Live panels showing CPU, RAM, and Disk usage of remote servers, alongside granular status, image, and resource usage for selected containers.
- 📋 **Visual Select & Clipboard Copy**: Use `v` to select lines of logs, and copy them easily via `y` to the system clipboard.
- 🌐 **Development Web View**: Render the exact same Terminal UI inside your web browser using Phoenix LiveView during local development for easy styling and debugging.
- 🔄 **On-Demand History**: Scroll up to automatically fetch older logs from the server-side log store.
- 📦 **Single-Binary Packaging**: Self-contained executable. No Elixir, Erlang, or external runtimes required on your machine.
- 🔄 **Self-Upgrades**: Stay up to date with a single command (`caudata upgrade`).

---

## 📦 Installation

### Quick Install (Recommended)

Run the following command to download and install the pre-compiled binary:

```bash
curl -fsSL https://raw.githubusercontent.com/quaywin/caudata/main/install.sh | sh
```

### Running from Source (Development)

Requires [mise](https://mise.jdx.dev/).

```bash
# Clone and setup
git clone https://github.com/quaywin/caudata.git
cd caudata

# Install tools & dependencies
mise install
mise exec -- mix deps.get

# Run development mode
mise exec -- mix run --no-halt
```

---

## 📖 Quick Start

1. **Start Caudata**:
   ```bash
   caudata
   ```
2. **Add Connections**:
   - **Remote Server (SSH)**: Caudata automatically scans your `~/.ssh/config`. If you need to add custom servers manually, press `a` or `+` in the TUI, select `+ Manual SSH Connection`, and fill in the details.
   - **Local Machine**: Press `a` or `+` in the TUI, select `+ Local Machine Connection`, and enter your local sudo password (optional, required if your local Docker or system logs require root permissions).
3. **Connect & Stream**: Use the TUI sidebar to select a host/local connection, hit `Enter` to connect, and Caudata will auto-discover running Docker containers. Toggle logs using `Space`.

---

## ⌨️ CLI Usage

```bash
# Show help menu
caudata --help

# Show current version
caudata --version

# Run the web UI server on port 4000 (default)
caudata web

# Run the web UI server on a custom port
caudata web --port 8080
# or
caudata web -p 8080

# Automatically upgrade to the latest release binary
caudata upgrade
```

---

## ⌨️ Keybindings (TUI Control)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Navigate sidebar or lists / Scroll logs up/down |
| `Enter` | Connect and start log streaming / Confirm action |
| `a` / `A` / `+` | Open the **Add Connection** modal |
| `s` / `S` | Open the **Global Settings** modal |
| `/` | Enter search mode to filter logs (Regex supported) |
| `Space` | Toggle options (e.g. enable/disable servers/containers/services) |
| `v` / `V` | Enter **Visual Select Mode** in the log pane |
| `y` / `Y` | Copy selected lines (in Visual Mode) or all logs to System Clipboard |
| `f` / `F` | Toggle logs full-screen view |
| `t` / `T` | Toggle displaying logs with timestamps |
| `Tab` | Switch focus between sidebar boxes (Servers / Containers) |
| `d` / `D` / `Backspace` | Delete selected server connection or custom log path |
| `Esc` | Clear active search, reset visual select mode, or close modals |
| `q` / `Q` | Exit Caudata |

---

## ⚙️ Configuration & Environment

Configuration is stored in an ETS-backed database at `~/.caudata/config.db` (managed automatically via the UI). Log buffers are capped at `1000` lines per stream to prevent high memory usage.

### Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `CAUDATA_CONFIG_PATH` | Path to customize the configuration DB location | `~/.caudata/config.db` |
| `CAUDATA_TUI` | Explicitly enable or disable Terminal UI (`true`/`false`) | Auto-detected |

### 🔑 Tailscale VPN Integration

Caudata supports establishing user-space Tailscale VPN connections without requiring an active system-wide Tailscale daemon on your host machine.

- **How it works**: When connecting to a remote server with a Tailscale IP (matching `100.64.0.0/10`) or MagicDNS (`*.ts.net`), Caudata automatically routes the SSH traffic through a secure local user-space proxy tunnel.
- **Configuration**: Set up Tailscale via the **Global Settings** modal (press `s` in the TUI) or pre-configure it by setting the `TAILSCALE_AUTHKEY` environment variable.

---

## 🌐 Development Web View

For easier debugging and layout testing, Caudata includes a Phoenix LiveView endpoint that allows you to view and interact with the TUI inside a web browser during local development.

To run Caudata in development with the web server active:
```bash
# This starts the Phoenix server at http://localhost:4000
mix run --no-halt
```
Open `http://localhost:4000` in your browser. Any changes you make to the UI code will automatically live-reload.

---

## 🏗️ Development & Testing

### Building Releases
To package Caudata into a single-binary using Burrito:
```bash
BURRITO_TARGET=macos_aarch64 mix release --overwrite
```
*(Available targets: `macos_x86_64`, `macos_aarch64`, `linux_x86_64`)*

### Testing
```bash
mix test
```

---

## 🗺️ Alternatives & Similar Projects

If you are looking for other tools to monitor or view logs, here is how **Caudata** compares to existing popular open-source alternatives:

| Project | Interface | Primary Focus | Multi-Server (SSH) | Docker Container Auto-Discovery | Zero-Agent / Zero-Config |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Caudata** | TUI & Web | Agentless Multi-Server Log/Metrics | Yes (native SSH config) | Yes (remote) | Yes |
| **[MultiTail](https://github.com/folkertvanheusden/multitail)** | TUI | Aggregated file/command logs | Yes (manual pipes) | No | No (requires manual config) |
| **[Dozzle](https://github.com/amir20/dozzle)** | Web | Docker container logs | Yes (requires agents) | Yes (needs setup) | No |
| **[lnav](https://github.com/tstack/lnav)** | TUI | Log parsing & SQL query | No (mainly local) | No | Yes (for local files) |
| **[Lazydocker](https://github.com/jesseduffield/lazydocker)** | TUI | Local Docker management | No | Yes (local only) | Yes (local only) |



---

## 🤝 Contributing

Contributions are welcome! Please feel free to open issues, submit pull requests, or share ideas to improve Caudata. Check out our [CONTRIBUTING.md](CONTRIBUTING.md) for local setup details.

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
