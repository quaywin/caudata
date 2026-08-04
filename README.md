# Caudata 🦎

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Caudata is a collaborative, zero-config multi-server log streamer, real-time metrics dashboard, and high-performance TUI engine. It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, as well as the **local machine**, without installing any agents on remote hosts.

⭐ If you like this project, star it on GitHub — it helps a lot!

[Features](#features) • [Performance & Benchmarks](#performance--benchmarks) • [Installation](#installation) • [Quick Start](#quick-start) • [CLI Options](#cli-options) • [Keybindings](#keybindings) • [Configuration](#configuration) • [Alternatives](#alternatives)

---

![Caudata TUI Demo](assets/demo.gif)

Tired of SSH-ing into 5 different servers just to tail Docker logs? Caudata brings them all (and your local setup) into a single, responsive terminal dashboard.

## Features

- **Zero-Agent SSH**: Connects seamlessly using your existing `~/.ssh/config` or custom server configurations. Supports both private keys and password authentication securely. No remote agents or daemons are required on target servers.
- **Local Machine Monitoring**: Monitor containers and services on your local machine using direct port communication (bypassing SSH).
- **Container Auto-Discovery**: Auto-discovers running Docker containers. Automatically reconnects active log streams when a container is rebuilt or restarted.
- **Docker Container Management**: Control Docker containers directly from the TUI — Start, Stop, Restart, Force Kill, Inspect, and Remove — with confirmation prompts for destructive actions.
- **System Services Support**: Stream logs from system daemon services running under **Systemd** (Linux) or **Launchd** (macOS).
- **Custom Log Paths**: Add and stream specific custom log paths from remote machines.
- **Real-time Server & Container Metrics**: Live panels showing CPU, RAM, and disk usage of remote servers, alongside granular status, image, and resource usage for selected containers.
- **⚡ Rust NIF Accelerated Log Engine**: Powered by [ex_log_formatter](https://github.com/quaywin/ex_log_formatter) via Rustler. Delivers **117,000 – 514,000 lines/sec** log parsing, zero-allocation ANSI code stripping (`strip-ansi-escapes`), and high-speed JSON/Logfmt/Text sub-element highlighting.
- **⏱️ Zero-Latency ETS Direct Read**: Log snapshots are stored in public ETS tables (`:caudata_log_buffers`) for zero-latency, non-blocking caller-process reads, bypassing GenServer mailbox queuing.
- **Visual Select & Clipboard Copy**: Press `v` to select lines of logs, and copy them via `y` to the system clipboard.
- **Development Web View**: Render the exact same Terminal UI inside your web browser using Phoenix LiveView for remote access, easy styling, or debugging.
- **Tailscale VPN Integration**: Connect securely to Tailscale hosts without requiring an active system-wide Tailscale daemon.
- **Single-Binary Packaging**: Self-contained executable (**14.1 MB**, **~62.88 MB Production RAM**) built with Burrito with no Elixir, Erlang, or external runtimes required on your target machine.
- **Self-Upgrades**: Stay up to date with a single command (`caudata upgrade`).

---

## 🚀 Performance & Benchmarks

Caudata is engineered for ultra-low memory footprint and high 60 FPS TUI scrolling over heavy log streams.

### Benchmark Matrix (Apple M2, 8GB RAM, Elixir 1.19.5 + Erlang 28.5 + Rust NIF)

| Component / Task | Before Optimization | **After Optimization** | Improvement | RAM Footprint |
| :--- | :--- | :--- | :--- | :--- |
| **ConfigStore.put_setting** | 91,340 ops/s (OS `:emfile` errors) | **726,010 ops/s** | 🚀 **8.0x Faster (Sạch 100% OS errors)** | 0.30 KB |
| **LogSanitizer.process_chunk**| 39,490 chunks/s | **123,610 chunks/s** | 🚀 **3.1x Faster** | ⬇️ **1.50 KB (-90.1% RAM)** |
| **LogFormatter (JSON Parsing)**| 29,800 lines/s | **111,970 lines/s** | 🚀 **3.8x Faster** | ⬇️ **5.61 KB (-52.6% RAM)** |
| **LogFormatter (Text SubHighlight)**| 18,590 lines/s | **49,050 lines/s** | 🚀 **2.6x Faster** | ⬇️ **4.12 KB (-68.3% RAM)** |
| **LogStore.get_snapshot** | 1,050 ops/s (952 μs latency) | **5,150 ops/s (121 μs latency)** | 🚀 **4.9x Faster** | 0.71 KB |
| **ViewHelper.get_displayed_logs**| 7,434.52 KB / filter | **4.59 KB / filter** | 💣 **1,620x RAM Reduction (-99.94%)** | **4.59 KB** |
| **Production Binary Idle RAM** | ~90 MB - 120 MB | **`62.88 MB`** | 🧠 **30% - 50% Idle RAM reduction** | **62.88 MB** |

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

## Keybindings

> Press `?` inside the TUI to open the full interactive keybinding reference.

### Global

| Key | Action |
| :--- | :--- |
| `1` / `h` / `←` | Jump focus to **Sidebar** panel |
| `2` / `l` / `→` | Jump focus to **Logs** panel |
| `Tab` | Toggle active panel focus / switch sidebar tabs |
| `a` / `A` | Open the **Add Connection** modal |
| `s` / `S` | Open the **Global Settings** modal |
| `f` / `F` | Toggle log panel full-screen view |
| `t` / `T` | Toggle displaying logs with timestamps |
| `?` | Toggle the **Help** modal |
| `q` / `Q` / `Ctrl+C` | Exit Caudata |

### Sidebar (Panel 1: Servers & Containers)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Navigate server & container tree |
| `Enter` | Connect to server / select container to stream |
| `Space` | Toggle log stream on/off |
| `m` / `M` | Open **Docker Container Actions** (Start/Stop/Restart/Kill/Inspect/Remove) |

### Logs Pane (Panel 2: Log Stream)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Scroll logs up/down (auto-accelerates on hold) |
| `g` / `G` | Jump to **top** (`g`) or **bottom** (`G`) of logs |
| `PageUp` / `PageDown` | Scroll logs page-by-page |
| `/` | Enter **live regex filter** search mode |
| `v` / `V` | Enter **Visual Select Mode** (extend selection with `j`/`k`) |
| `y` / `Y` | Copy all displayed logs (or selected lines in Visual Mode) to clipboard |
| `o` | Swap anchor/cursor ends (in Visual Select Mode) |
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
| **Caudata** | TUI & Web | Agentless Multi-Server Log/Metrics | **Yes** (native SSH config) | **Yes** (remote/local) | **514k lines/s (`62.88 MB` RAM)** |
| **[MultiTail](https://github.com/folkertvanheusden/multitail)** | TUI | Aggregated file/command logs | Yes (manual pipes) | No | ~50k lines/s (~80 MB RAM) |
| **[Dozzle](https://github.com/amir20/dozzle)** | Web | Docker container logs | Yes (requires agents) | Yes (needs setup) | ~50k lines/s (~70 MB RAM) |
| **[lnav](https://github.com/tstack/lnav)** | TUI | Log parsing & SQL query | No (mainly local) | No | ~300k lines/s (~80 MB RAM) |
| **[Lazydocker](https://github.com/jesseduffield/lazydocker)** | TUI | Local Docker management | No | Yes (local only) | ~40k lines/s (~100 MB RAM) |
