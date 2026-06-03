# Contributing to Caudata

Thank you for your interest in contributing to Caudata!

## Getting Started

### Prerequisites

- [mise](https://mise.jdx.dev/) installed for toolchain management
- Git

### Development Setup

```bash
# Fork and clone the repository
git clone https://github.com/<your-username>/caudata.git
cd caudata

# Install toolchains (Elixir, Erlang, Zig)
mise install

# Fetch dependencies
mise exec -- mix deps.get

# Run in development mode
mise exec -- mix run --no-halt

# Run tests
mise exec -- mix test
```

## How to Contribute

### Reporting Bugs

- Use the [Bug Report](https://github.com/quaywin/caudata/issues/new?template=bug_report.md) issue template.
- Include steps to reproduce, expected vs actual behavior, and your environment details.

### Suggesting Features

- Use the [Feature Request](https://github.com/quaywin/caudata/issues/new?template=feature_request.md) issue template.
- Describe the problem you're solving and your proposed solution.

### Submitting Changes

1. **Fork** the repository and create a new branch from `main`:
   ```bash
   git checkout -b feat/my-feature
   ```

2. **Make your changes** — keep them focused and minimal.

3. **Write or update tests** for your changes:
   ```bash
   mise exec -- mix test
   ```

4. **Format your code**:
   ```bash
   mise exec -- mix format
   ```

5. **Commit** with a clear, descriptive message following [Conventional Commits](https://www.conventionalcommits.org/):
   ```
   feat: add support for custom log formats
   fix: prevent crash when SSH connection drops
   docs: update configuration examples
   ```

6. **Push** your branch and open a **Pull Request** against `main`.

## Code Style

- Follow the standard Elixir formatting (`mix format`).
- Keep modules focused and well-documented with `@moduledoc` and `@doc`.
- Prefer pattern matching and pipeline operators where they improve readability.

## Code of Conduct

This project follows the [Contributor Covenant Code of Conduct](CODE_OF_CONDUCT.md). By participating, you are expected to uphold this code.

## Questions?

Feel free to open an issue for any questions about contributing. We're happy to help!
