# Changelog

## v1.1.0 — 2026-03-08

### Added
- **Linux support** — portable OAuth token retrieval (Keychain on macOS, credentials file on Linux), GNU/BSD date parsing, cross-platform package manager detection
- **Preset system** — 5 presets (Minimal, Clean, Standard, Developer, Full) in both TUI and bash wizard
- **Auto-install uv + textual** — installer downloads `uv` and runs TUI via `uv run --with textual` if textual is not already installed
- **AI install wizard** — `INSTALL.md` guide for Claude Code to install clickline via `AskUserQuestion` with preview panes
- **Bash wizard parity** — presets, advanced options, and final preview now match the TUI configurator
- **`.gitignore`** — dev files (CLAUDE.md, HANDOFF.md, .doc-manifest.yaml) excluded from repo

### Fixed
- `curl | bash` install now correctly launches the interactive wizard (stdin redirected from `/dev/tty`)
- `local` keyword removed from top-level scope (caused syntax errors on Linux)
- TUI crash no longer kills the installer (`set -e` handled via conditional)
- Textual install no longer blocked by PEP 668 externally managed Python environments

## v1.0.0 — 2026-03-06

Initial release.
