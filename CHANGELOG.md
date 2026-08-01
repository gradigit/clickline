# Changelog

## Unreleased

### Security
- **`clickline.conf` is parsed, not sourced** — the statusline no longer runs `source` on the config file, so a malformed or hostile config can no longer execute arbitrary shell code on every render. Values are read with an allowlist of known keys (`SHOW_*`, `LAYOUT`, `THEME`, `*_CACHE_TTL`, and friends).

### Changed
- **BREAKING: config values are now literal.** `source` expanded `$VAR`, `$(command)` and backticks inside config values; the parser stores them verbatim. Self-referential settings such as `LAYOUT="$LAYOUT custom_x"` silently stop working — write the full value out instead. Values needing spaces or `#` should be quoted, e.g. `LAYOUT='path branch | context cost'`.
- `LAYOUT` in `clickline.conf.default` is now single-quoted. Unquoted, `bash` parsed the `|` as a pipeline, so `source` never actually set `LAYOUT`.
- Unrecognized config keys are now reported on stderr instead of being dropped silently. The warning never reaches the statusline itself, which is written to stdout.

### Fixed
- Custom items are found whether the JSON key is `name` or `custom_name`, matching how they are referenced in `LAYOUT`.
- A quoted config value containing `" #"` is no longer truncated. Comment stripping ran before quote handling, so `LAYOUT='path branch # foo'` parsed as `'path branch` — a poisoned first token that silently stopped `path` from rendering.
- Config parsing no longer forks a `printf | sed` pipeline per line, which added ~194 ms to every statusline render (measured under bash 3.2 on macOS with a 29-line config). Render time is back to within noise of pre-parser builds.

### Added
- `test/conf-parse.sh` — covers comment/quote interaction, literal-value handling, and unrecognized-key warnings.

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
