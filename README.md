# Caudata 🌯

**Caudata** is a collaborative, zero-config multi-server log streamer built with **Elixir/OTP**, **Ratatui (TUI)**, and **Phoenix LiveView**. 

It aggregates and streams real-time logs from multiple remote Linux servers securely over SSH config profiles, without installing any agents on remote hosts. The system utilizes supervised OTP processes, bounded per-source ring buffers, and renders a single interactive application across multiple targets (CLI/TUI, Web Browser, and Collaborative SSH terminal multiplexing).

---

## 🚀 Features

- **Multi-Server Aggregation**: Automatically discovers SSH connections in `~/.ssh/config` and streams logs using Erlang's native `:ssh` and `:ssh_connection` (no external `ssh` binary required).
- **Multiple Rendering Targets**:
  - **Local Terminal UI (TUI)**: Fully interactive TUI in your command line.
  - **Web Mirror (Phoenix LiveView)**: Mirrors the interactive terminal directly to your web browser with a bounded DOM viewport.
  - **Collaborative SSH Server**: Connect to Caudata over SSH using terminal multiplexing.
- **Single-Binary Packaging**: Self-extracting executables containing the entire application and the Erlang runtime (no dependency on Elixir/Erlang on the host machine).
- **Resilient & Safe**: Bounded ring buffers (1000 lines per source) with drop accounting and process-isolated workers. Invalid filter regexes are safely caught without crashing.

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

## 🛠️ Usage & Commands

### Running the Installed Binary

Once installed via `curl | sh`, you can run it anywhere:

```bash
# Start Caudata TUI and Web Mirror
caudata
```

### Self-Extracting Binary Maintenance (Burrito-specific)

Since Caudata is packaged as a Burrito binary, you have access to built-in maintenance commands:

```bash
# Get binary metadata (versions of OTP, Elixir, App)
caudata maintenance meta

# Print the folder where Caudata's runtime payload was extracted
caudata maintenance directory

# Uninstall/Clean up the extracted payload from your system
caudata maintenance uninstall
```

---

## 🤝 Collaborative SSH TUI Server

Caudata includes a built-in SSH server allowing multiple users to connect to the active Caudata terminal interface securely and collaborate.

### 1. Configure the SSH Server

You can manage the SSH server via the config file (`~/.caudata/config.toml`) or environment variables:

| Environment Variable | Description | Default |
| --- | --- | --- |
| `CAUDATA_SSH_ENABLED` | Set to `true` to enable the collaborative SSH server | `false` |
| `CAUDATA_SSH_IP` | Bind address. `127.0.0.1` by default; set to `any` or `0.0.0.0` for public | `127.0.0.1` |
| `CAUDATA_SSH_PORT` | Port to listen on | `2222` |
| `CAUDATA_SSH_KEYS_DIR` | Directory where SSH host keys are generated and persisted | `~/.caudata/ssh_keys` |

### 2. Booting the SSH Server

To start Caudata with the collaborative SSH server enabled:

```bash
CAUDATA_SSH_ENABLED=true CAUDATA_SSH_PORT=2222 caudata
```

### 3. Connecting to the Shared Session

Any authorized terminal user can securely attach to the live Caudata session from their terminal:

```bash
ssh localhost -p 2222
```

---

## ⚙️ Configuration

Caudata looks for a configuration file at `~/.caudata/config.toml`. If it doesn't exist, a default config will be created automatically on the first boot.

### Config File Format

Here is an example `config.toml` structure:

```toml
[global]
# Bounded queue capacity for logs (default: 1000 lines per server)
capacity = 1000

# Default command to run on remote servers to stream logs
log_command = "tail -F /var/log/messages"

# Whether to auto-discover connection profiles from ~/.ssh/config (default: true)
discover_ssh_config = true

[ssh_server]
# Enable the collaborative SSH UI server (default: false)
enabled = false
ip = "127.0.0.1"
port = 2222
host_keys_dir = "~/.caudata/ssh_keys"

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

In addition to the SSH configurations, you can configure the HTTP Web interface:

- `PORT`: HTTP port for Phoenix Web mirror (default: `4000` in prod/dev, `4002` in test).
- `CAUDATA_IP`: Bind address for the Web server (default: `127.0.0.1`, set to `any` or `0.0.0.0` to allow external connections).
- `SECRET_KEY_BASE`: Phoenix Session security key (optional, automatically generated if not supplied).

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
