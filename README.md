# Caudata 🦎

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Caudata is a collaborative, zero-config multi-server log streamer, real-time metrics dashboard, and high-performance TUI engine. It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, as well as the **local machine**, without installing any agents on remote hosts.

⭐ If you like this project, star it on GitHub — it helps a lot!

[Features](#features) • [Installation](#installation) • [Quick Start](#quick-start) • [CLI Options](#cli-options) • [Keybindings & Mouse Controls](#keybindings--mouse-controls) • [Configuration](#configuration) • [Alternatives](#alternatives)

---

![Caudata TUI Demo](assets/demo.gif)

Tired of SSH-ing into 5 different servers just to tail Docker logs? Caudata brings them all (and your local setup) into a single, responsive terminal dashboard.

- **Zero-Agent SSH**: Connects seamlessly via `~/.ssh/config` or manual settings. No remote agents or daemons required.
- **Local Machine Monitoring**: Monitor local containers and system services via direct connection.
- **Container Auto-Discovery**: Auto-discovers Docker containers and reconnects log streams on container rebuilds/restarts.
- **Docker Management**: Control containers directly — Start, Stop, Restart, Kill, Inspect, and Remove.
- **System Services & Custom Logs**: Stream Systemd (Linux), Launchd (macOS), or custom file paths.
- **Real-time Metrics**: Live CPU, RAM, and disk monitoring for hosts and granular stats for containers.
- **✨ `hl` Standard Structured Layout**: Automatically formats JSON, Logfmt, and plain text into clean, human-readable lines: `[TIMESTAMP] [LEVEL] (SERVICE) MESSAGE  key1=val1 key2=val2`.
- **🎨 Sub-Element Syntax Highlighting**: Native token highlighting for IPv4/IPv6, URIs/paths, HTTP methods/statuses, durations (`ms`/`s`), UUIDs, and numbers.
- **📊 Quick Log Level Filtering (`[l]`)**: Instant modal selector to filter logs by exact severity (`All`, `INFO only`, `WARN only`, `ERROR only`).
- **⚡ Rust NIF Accelerated Engine**: High-throughput log ingest, parsing, and ANSI/escape sanitization powered by Rustler.
- **⏱️ Zero-Latency ETS Direct Read**: ETS-backed log buffers for non-blocking snapshot reads.
- **🖱️ Mouse & Visual Controls**: SGR mouse support for scroll wheeling, drag-to-copy, sidebar clicking, footer action bar, and modal backdrop closing.
- **Development Web View**: Render the exact TUI inside a web browser via Phoenix LiveView.
- **Tailscale VPN Integration**: Connect to Tailscale hosts without a system daemon.
- **Single-Binary Packaging**: Self-contained Burrito executable (~13 MB binary, ~84 MB idle RAM).
- **Self-Upgrades**: Stay up to date with `caudata upgrade`.

---

## Installation

### Quick Install (Recommended)

Run the following command to download and install the pre-compiled binary:

```bash
curl -fsSL https://raw.githubusercontent.com/quaywin/caudata/main/install.sh | sh
```

### Running/Building from Source

Caudata uses [mise](https://mise.jdx.dev/) to manage development runtimes:

```bash
# Clone the repository
git clone https://github.com/quaywin/caudata.git
cd caudata

# Install required tools (Erlang, Elixir, Zig, and Rust)
mise install

# Install Elixir dependencies
mix deps.get

# Run development mode
mix run --no-halt
```

To build a standalone executable release using [Burrito](https://github.com/burrito-elixir/burrito):

```bash
# Build for your current host architecture
mix release --overwrite

# Build for a specific target platform
BURRITO_TARGET=macos_aarch64 mix release --overwrite
```

> [!NOTE]
> Available target profiles include: `macos_x86_64`, `macos_aarch64`, `linux_x86_64`.

---

## Quick Start

1. **Launch Caudata**:
   ```bash
   caudata
   ```
2. **Add Connections**:
   - **Remote Server (SSH)**: Caudata automatically scans your `~/.ssh/config`. To add custom servers manually, press `a` in the TUI, select `+ Manual SSH Connection`, and fill in the details.
   - **Local Machine**: Press `a` in the TUI, select `+ Local Machine Connection`, and enter your local sudo password (optional, required if your local Docker or system logs require root permissions).
3. **Connect & Stream**: Use the TUI sidebar to select a host or local connection, press `Enter` to connect, and Caudata will auto-discover running Docker containers and services. Toggle active log streams using `Space`.

---

## CLI Options

```bash
# Show help menu
caudata --help        # or: caudata -h

# Show current version
caudata --version     # or: caudata -v

# Run the web UI server on port 4000
caudata web

# Run the web UI server on a custom port and address
caudata web --port 8080   # or: caudata web -p 8080
CAUDATA_IP=0.0.0.0 caudata web

# Run the web UI server with user-space Tailscale VPN tunneling
caudata web --port 8080 --tailscale --authkey <your-tailscale-key> --tailscale_port 80

# Automatically upgrade to the latest release binary
caudata upgrade
```

---

## Keybindings & Mouse Controls

> Press `?` inside the TUI to open the full interactive keybinding reference.

### 🖱️ Mouse Controls

| Gesture | Location | Action |
| :--- | :--- | :--- |
| **Scroll Wheel** | Logs Pane | Scroll log stream (auto-fetches history at top) |
| **Drag & Select** | Logs Pane | Highlight log range & auto-copy to OS clipboard on release |
| **Left Click** | Sidebar | Select server/container & start stream |
| **Left Click** | Footer Bar | Trigger action shortcut (`[a] Add`, `[s] Settings`, `[l] Level`, `[?] Help`, etc.) |
| **Left Click** | Modals | Switch tabs, pick actions, or click backdrop to close (`Esc`) |

### Global

| Key | Action |
| :--- | :--- |
| `1` / `2` / `3` | Jump focus directly to **Servers (1)**, **Containers (2)**, or **Logs (3)** |
| `Tab` / `←` / `→` | Cycle active panel focus (1 ↔ 2 ↔ 3) |
| `l` / `L` | Open the **Log Level Filter** modal (`All`, `INFO`, `WARN`, `ERROR`) |
| `a` / `A` | Open the **Add Connection** modal |
| `s` / `S` | Open the **Global Settings** modal |
| `f` / `F` | Toggle log panel full-screen view |
| `t` / `T` | Toggle displaying logs with timestamps |
| `?` | Toggle the **Help** modal |
| `q` / `Q` / `Ctrl+C` | Exit Caudata |

### Servers & Containers (Panels 1 & 2)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Navigate server & container list |
| `Enter` | Connect to server / select container to stream |
| `Space` | Toggle log stream on/off |
| `m` / `M` | Open **Docker Container Actions** (Start/Stop/Restart/Kill/Inspect/Remove) |

### Logs Pane (Panel 3)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Scroll logs up/down (auto-accelerates on hold) |
| `g` / `G` | Jump to **top** (`g`) or **bottom** (`G`) of logs |
| `PageUp` / `PageDown` | Scroll logs page-by-page |
| `/` | Enter **live regex filter** search mode (supports `!` for negative filter) |
| `v` / `V` | Enter **Visual Select Mode** (extend selection with `j`/`k` or mouse) |
| `y` / `Y` | Copy all displayed logs (or selected lines in Visual Mode) to clipboard |
| `o` | Swap anchor/cursor ends (in Visual Select Mode) |
| `Space` | Pause / Resume live log auto-scrolling (`[PAUSED]`) |
| `Esc` | Clear active filter regex / exit visual mode |

---

## Configuration

Settings and connection profiles are stored in an ETS-backed database at `~/.caudata/config.db`. Caudata automatically defaults the log buffer capacity to `10,000` lines per stream with zero-lag virtualized rendering to maintain low memory footprint and high 60 FPS performance.

### Environment Variables

| Variable | Description | Default |
| :--- | :--- | :--- |
| `CAUDATA_CONFIG_PATH` | Directory or file path for the configuration database. | `~/.caudata/config.db` |
| `CAUDATA_TUI` | Explicitly enable or disable the Terminal UI (`true`/`false`). | Auto-detected |
| `CAUDATA_IP` | Bind address for the web server (e.g. `127.0.0.1` or `0.0.0.0`). | `127.0.0.1` |
| `PORT` | Port to run the web server on when running `caudata web`. | `4000` |
| `TAILSCALE_AUTHKEY` | Tailscale authorization key for VPN integration. | None |

---

## Alternatives

If you are looking for other tools to monitor or view logs, here is how Caudata compares to existing open-source options:

| Project | Interface | Primary Focus | Multi-Server (SSH) | Docker Container Auto-Discovery | Peak Throughput / RAM |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Caudata** | TUI & Web | Agentless Multi-Server Log/Metrics | **Yes** (native SSH config) | **Yes** (remote/local) | **~270k lines/s ingest (`~84 MB` RAM)** |
| **[MultiTail](https://github.com/folkertvanheusden/multitail)** | TUI | Aggregated file/command logs | Yes (manual pipes) | No | ~50k lines/s (~80 MB RAM) |
| **[Dozzle](https://github.com/amir20/dozzle)** | Web | Docker container logs | Yes (requires agents) | Yes (needs setup) | ~50k lines/s (~70 MB RAM) |
| **[lnav](https://github.com/tstack/lnav)** | TUI | Log parsing & SQL query | No (mainly local) | No | ~300k lines/s (~80 MB RAM) |
| **[Lazydocker](https://github.com/jesseduffield/lazydocker)** | TUI | Local Docker management | No | Yes (local only) | ~40k lines/s (~100 MB RAM) |
