# Changelog

## v1.2.0 — 2026-11-04

### Fixed
- **Quota stuck on `—` / usage API rate-limited (HTTP 429)** — responses were only accepted if `five_hour` was non-null, so on plans or periods without a 5-hour window every valid response was discarded. The cache never refreshed, and every session re-called the endpoint on every render until the API returned 429. Either window may now be null, and fallback calls are throttled across all sessions with exponential backoff (up to 1h).
- **`gh pr view` called on every render for branches without a PR** — `gh` exits 1 when there's no PR, and the stale-cache refresh only wrote on success. Lookups are now stamped before fetching and record "no PR", so each repo is looked up at most once per `PR_CACHE_TTL` across all sessions. The same fix applies to CI status.
- **Cache cleanup scanned all of `/tmp` on every render** — it now runs at most once a day and only checks the top level of `/tmp`
- **GitHub links for `https://user@github.com/...` remotes** — now recognized
- **Dirty count** counted a file twice when it was both staged and modified. It's now a single `git status` call that never takes `index.lock`, so it can't collide with git commands running in the session.
- **Effort / thinking label** — read from the current statusline input fields (`effort.level`, `thinking.enabled`)
- **`install.sh --quota`** — accepts responses without a 5-hour window, reports both windows, explains 429s, and no longer multiplies utilization (already a percentage) by 100
- Quota windows whose reset time has passed now show 100% instead of the old value with "(now)"
- Cache files are written atomically

### Added
- **Quota from Claude Code's statusline input** (`rate_limits`) — no API call or credentials needed on recent Claude Code versions; the OAuth endpoint remains a fallback. Each window renders on its own, so plans with only a weekly limit show just that.
- **Quota shared across sessions** — each session only knows the quota as of its own last response, so the highest value seen for the current window is shared and idle sessions don't show stale numbers
- **PR from Claude Code's statusline input** (`pr`) — an open PR shows without clickline calling GitHub
- **`cache` element** (`SHOW_CACHE`) — time until the prompt cache goes cold (orange in the last 20% of its TTL, red when cold) plus the session's cache hit rate. Added to the default layout and the Standard/Developer/Full presets.
- `PATH_LINK_TARGET=none` also drops the transcript `file://` link on the cost element (for ssh/mosh sessions, where file links can't open)
- Stale fallback quota older than `QUOTA_MAX_AGE` (default 900s) shows `Quota —` instead of misleading numbers

### Changed
- **Repo-local `.clickline` items are static** — `cmd` and `condition` are ignored there, since both are run as shell commands and any repo you open could otherwise run commands through your statusline. Dynamic items still work from `~/.claude/clickline-custom.json`. The TUI's repo-item dialog no longer offers a command field.
- "New PR" link no longer starts `python3` just to URL-encode the branch name (about a third of render time)

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
