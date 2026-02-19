# clickline

Compact, clickable 2-line statusline for [Claude Code](https://claude.ai/code). Every element that can be a link is one — Cmd+click your working directory, git branch, PR, or quota directly from the statusline.

![preview](preview.svg)

## Features

- **OSC-8 hyperlinks** — path opens in Finder/editor, branch opens on GitHub, quota opens claude.ai, cost opens your session transcript
- **Per-repo service links** — add clickable links to Railway, Vercel, Supabase, and more via `.clickline`
- **2-line layout** — directory · branch · model on line 1; context window · quota · cost on line 2
- **Catppuccin Mocha** palette with semantic colors — green → yellow → red as limits fill
- **Config-driven** — toggle any element on/off via a config file, no script editing
- **Interactive installer** — fzf multi-select (or numbered fallback) to choose what to show
- **Smart truncation** — long paths show last 2 segments, branch names cap at 25 chars
- **PR + CI** — open PR number (clickable), "New PR" shortcut, CI status ✓ ✗ ⋯ (all async, never blocks)
- **Quota tracking** — 5-hour and 7-day usage with time-until-reset, cached and stale-while-revalidated
- **Context window** — percentage + max size, with ⚠️ / 🚨 warnings at 60% and 80%
- **Dirty indicator** — ·N shows count of modified/staged files after branch name

## Requirements

- [Ghostty](https://ghostty.org) — OSC-8 and 24-bit color support required (iTerm2, WezTerm also work)
- [Claude Code](https://claude.ai/code)
- `jq`, `git`, `curl`
- macOS (uses BSD `date` and `security` keychain for OAuth token)
- `gh` CLI — optional, needed for PR and CI features

## Installation

```sh
curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/install.sh | bash
```

The installer will:
1. Check dependencies
2. Let you choose which elements to show (fzf multi-select or numbered menu)
3. Choose where Cmd+click on the path opens (Finder, VS Code, Cursor, or nothing)
4. Write `~/.claude/clickline.conf` with your settings
5. Copy `statusline.sh` to `~/.claude/statusline.sh`
6. Update `~/.claude/settings.json`

### Reconfigure

Run the installer again at any time to change settings. Changes take effect on the next Claude Code response — no restart needed.

```sh
bash ~/.claude/statusline-install.sh
# or, if you cloned the repo:
bash install.sh
```

### Manual install

```sh
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/gradigit/clickline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
cp clickline.conf.default ~/.claude/clickline.conf
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash /Users/YOU/.claude/statusline.sh",
    "timeout": 5000
  }
}
```

## What's clickable

| Element | Destination |
|---|---|
| Working directory | `file://` — opens in Finder / VS Code / Cursor |
| Git branch | `https://github.com/owner/repo/tree/branch` |
| PR `#N` | Pull request page |
| `New PR` | GitHub compare page to open a PR |
| CI symbol (✓ ✗ ⋯) | GitHub Actions run page |
| 5h quota % | `https://claude.ai/settings/usage` |
| 7d quota % | `https://claude.ai/settings/usage` |
| `Quota —` (unavailable) | `https://claude.ai/settings/usage` |
| Commit hash | `https://github.com/owner/repo/commit/SHA` |
| Model name | `https://docs.anthropic.com/en/docs/about-claude/models/overview` |
| Version | `https://github.com/anthropics/claude-code/releases` |
| Session cost | `file://` — opens session transcript (JSONL) |
| Service links | Custom URLs from `.clickline` (Railway, Vercel, Supabase, …) |

OSC-8 links require a terminal that supports them. Ghostty, iTerm2, and WezTerm all do. Cmd+click (macOS) activates the link.

## Layout

```
my-app/src · feat/dark-mode·3 ↑2 │ #42 │ ✓ │ Claude Sonnet 4.6 │ backend · frontend · db
35%/200K │ 85% (2h3m) · 61% (3d5h) │ $4
```

**Line 1:** `path [· branch [·dirty] [↑N ↓N]] [│ commit] [│ PR] [│ CI] [│ model [thinking]] [│ version] [│ VIM] [│ agent] [│ service links]`

**Line 2:** `ctx%/maxK [warn] │ 5h% (reset) · 7d% (reset) │ $cost`

## Config reference

`~/.claude/clickline.conf` (created by installer, or copy from `clickline.conf.default`):

```bash
# Features (true/false)
SHOW_BRANCH=true
SHOW_DIRTY=true          # ·N modified/staged files after branch
SHOW_AHEAD_BEHIND=false  # ↑N ↓N commits ahead/behind remote
SHOW_COMMIT=false        # HEAD short hash → GitHub commit
SHOW_PR=true             # #N or "New PR" (requires gh)
SHOW_CI=false            # ✓ ✗ ⋯ GitHub Actions (requires gh)
SHOW_MODEL=true
SHOW_VERSION=false       # Claude Code version
SHOW_CONTEXT=true
SHOW_QUOTA=true
SHOW_COST=true

# Options
BRANCH_MAX_CHARS=25      # truncate long branch names
PATH_SEGMENTS=2          # show last N path segments
PATH_LINK_TARGET=finder  # finder | vscode | cursor | none
PR_CACHE_TTL=60          # seconds between PR cache refreshes
CI_CACHE_TTL=30          # seconds between CI cache refreshes
QUOTA_CACHE_TTL=60       # seconds between quota cache refreshes
```

Colors follow the same green → yellow → red progression for context, 5h quota, and 7d quota (< 50% green, < 75% yellow, ≥ 75% red). Cost is ceiling-rounded to whole dollars.

## Quota troubleshooting

If quota shows `—`, run:

```sh
bash install.sh --quota
```

This walks through all steps (keychain entry, token extraction, API call) and shows a specific fix message for each failure mode. The most common fix is:

```
/logout
/login
```

in Claude Code to refresh OAuth token scopes.

## PR and CI features

PR and CI data is fetched via the `gh` CLI. Install and authenticate:

```sh
brew install gh
gh auth login
```

Both use a stale-while-revalidate cache — they never block the statusline render. Data appears on the next response after the cache warms (typically 1 response delay on first use for a branch).

PR segment is hidden on the default branch (main/master) since PRs don't apply there.

## Service links

Add clickable links for your deployment and infrastructure services by creating a `.clickline` file in the repository root:

```json
{
  "services": [
    {"label": "backend", "url": "https://myapp.up.railway.app"},
    {"label": "frontend", "url": "https://myapp.vercel.app"},
    {"label": "db", "url": "https://supabase.com/dashboard/project/abc123"}
  ]
}
```

Service names appear in the statusline and open the URL on Cmd+click. Services render in list order.

**Interactive setup** — run `/service-links` in Claude Code to add or update links interactively.

Add `.clickline` to `.gitignore` if your dashboard URLs are team-specific or sensitive.

## License

MIT
