# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.75] - 2026-08-20

### Fixed & Resiliency

- Fixed reconnect hanging on machine sleep/wake by adding bounded connect (15s) and discovery (15s) timeouts
- Bounded health checks to 5s to rapidly detect and recover from dead/half-open TCP sockets
- Configured TCP socket keepalive (`inet_args: [keepalive: true, nodelay: true]`) and reduced SSH idle time from 300s to 60s
- Optimized reconnect backoff cap from 30s to 10s and immediate 1s reset on manual refresh
- Preserved bounded memory consumption during reconnects via stream limits (max 5 active) and clamped timestamp lookbacks (max 1h)

## [0.1.74] - 2026-08-19

### Performance & CI/CD

- Added workflow timeouts (25m build / 10m release) to prevent runaway hung jobs
- Added comprehensive CI caching for Mix dependencies (`deps/`, `_build/`), Rust/Cargo targets, and Burrito downloads
- Switched Burrito NIF patching from `:httpc` to `Req` with bounded timeouts and automatic retries
- Optimized Linux (`apt-get`) and macOS (Homebrew) CI package installations
- Removed obsolete tailscale clean step from release pipeline

## [0.1.59] - 2026-07-29

### Refactored & Cleaned

- Resolved all Elixir compiler warnings (0 warnings)
- Extracted duplicate `process_chunk/2` stream buffer splitting logic into `Caudata.LogSanitizer.process_chunk/2`
- Consolidated ANSI escape code stripping via `Caudata.LogSanitizer.strip_ansi_escapes/1`
- Unified `docker_container?/1` identification logic into `Caudata.UI.ViewHelper.docker_container?/1`

## [0.1.58] - 2026-07-29

### Fixed

- Prevented SSH channel leak on `validate_path` execution errors
- Optimized log accumulation in `ContainerWorker` from $O(N^2)$ to $O(1)$ amortized
- Implemented atomic file persistence (tmp file + rename) in `ConfigStore` to prevent config corruption
- Added connection task monitoring and instant crash recovery in `ServerWorker`
- Added `delete_stream/2` API to `LogStore` for async stream memory cleanup
- Added bounded 10s timeout to `Task.await_many` during `ServerWorker.terminate/2`
- Fixed race condition in `ConfigManager.delete_profile` with synchronous worker teardown
- Added Docker container management modal and inspect view in TUI

## [0.1.0] - 2025-01-01

### Added

- Multi-server log streaming over SSH using Erlang's native `:ssh`
- Docker container auto-discovery on remote hosts
- Interactive Terminal UI (TUI) with Ratatui
- Web mirror via Phoenix LiveView
- Bounded ring buffers with drop accounting
- Real-time regex log filtering
- SSH config auto-discovery from `~/.ssh/config`
- TOML configuration file support (`~/.caudata/config.toml`)
- Single-binary packaging with Burrito
- Curl-based installer script

[Unreleased]: https://github.com/quaywin/caudata/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/quaywin/caudata/releases/tag/v0.1.0
