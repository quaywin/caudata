# Caudata 🌯

[![Build and Release](https://github.com/quaywin/caudata/actions/workflows/release.yml/badge.svg)](https://github.com/quaywin/caudata/actions/workflows/release.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

**Caudata** is a collaborative, zero-config multi-server log streamer built with **Elixir/OTP**, **Ratatui (TUI)**, and **Phoenix LiveView**. 

It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, without installing any agents on remote hosts.

---

## 🚀 Features

- 🐳 **Real-Time Docker Lifecycle**: Auto-discovers containers on connection and streams `docker events` to track container startup, stops (`die`), destruction, or rebuilds in real-time, auto-resuming log streams seamlessly.
- 📄 **Granular Log Streaming**: Stream specific containers or custom log paths.
- 🔗 **Multi-Server Aggregation**: Discovers and connects using SSH profiles in `~/.ssh/config`.
- 🖥️ **Dual UI Targets**: 
  - **Local TUI**: Fully interactive Terminal UI.
  - **Web Mirror**: Mirrors the interactive terminal to your browser using Phoenix LiveView.
- ⚡ **Event-Driven & Batched Performance**: Eliminates polling by utilizing Phoenix PubSub to drive UI updates reactively, and buffers log streams in worker processes to flush in 100ms batches, minimizing write pressure.
- 📦 **Single-Binary Packaging**: Self-contained executables (no Elixir/Erlang runtime required on host).

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
- **TUI** starts directly in your terminal.
- **Web UI Mirror** is available at [http://localhost:4000](http://localhost:4000).

---

## ⌨️ Keybindings (TUI Control)

| Key | Action |
| :--- | :--- |
| `↑` / `↓` (or `k` / `j`) | Navigate sidebar or lists |
| `Enter` | Connect and start log streaming / Confirm action |
| `a` / `A` / `+` | Open the **Add SSH Connection** modal |
| `s` / `S` | Open the **Global Settings** modal |
| `/` | Enter search mode to filter logs (Regex supported) |
| `Space` | Toggle options (e.g. enable/disable servers/containers) |
| `d` / `D` / `Backspace` | Delete selected server connection or custom log path |
| `Esc` | Clear active search or close modals |
| `q` / `Q` | Exit Caudata |

---

## ⚙️ Configuration & Environment

- Configuration is stored at `~/.caudata/config.db` (managed automatically via the UI).
- Log buffers are capped at `1000` lines per stream to prevent high memory usage.

### Environment Variables
- `PORT`: Web mirror HTTP port (default: `4000`).
- `CAUDATA_IP`: Web mirror bind address (default: `127.0.0.1`, set to `0.0.0.0` to allow external access).

---

<details>
<summary>🛠️ Under the Hood: Safety & SSH Resource Limits (Click to expand)</summary>

### 🛡️ Process Cleanup & Safety
To prevent orphaned processes on remote servers, Caudata runs streaming commands (like `docker logs`) inside a secure POSIX-compliant wrapper:
```bash
sh -c 'docker logs --follow <container> & pid=$!; trap "kill $pid 2>/dev/null" EXIT HUP INT TERM; read -r _; kill $pid 2>/dev/null'
```
- **Active Trapping**: Sends EOF on channel close to terminate remote processes cleanly.
- **Abrupt Disconnections**: Laptop sleep or network drops will trigger the trap and kill the `docker logs` process.

### 🔌 SSH Channel Limits & GC
Most SSH servers limit concurrent active channels (usually 10). Caudata implements an **automatic Least Recently Used (LRU) channel garbage collector**:
- When active channels reach **8**, opening a new stream will automatically terminate the oldest inactive stream first to prevent connection errors.

### 🔄 Real-Time Container Rebuilds
Caudata monitors container state changes dynamically using a remote event stream:
- **`docker events` Tracking**: Streams container lifecycle events (`start`, `die`, `destroy`) in JSON format.
- **Seamless Rebuild Recovery**: When a container is recreated or restarted (rebuilt with a new ID but the same name), Caudata automatically shifts the active logging worker's connection to the new container ID and resumes the log stream seamlessly, ensuring zero manual reconnection effort.

### ⚡ Batching & Event-Driven Rendering
To keep CPU/IO footprint low even with high-throughput logs:
- **Log Buffering**: Rather than writing each incoming chunk to the database immediately, worker processes buffer log streams and perform batched flushes every 100ms.
- **PubSub-Driven UI**: Polling of the local state cache has been replaced with Phoenix PubSub subscriptions. The UI only redraws and fetches logs when notified of change events (e.g., `:logs_updated` or `:status_updated`).
</details>

---

## 🏗️ Development & Testing

### Building Releases
To package Caudata into a single-binary using Burrito:
```bash
BURRITO_TARGET=macos_aarch64 mise exec -- mix release --overwrite
```
*(Available targets: `macos_aarch64`, `macos_x86_64`, `linux_x86_64`)*

### Testing
```bash
mise exec -- mix test
```

---

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
