# clickline

Compact, clickable 2-line statusline for [Claude Code](https://claude.ai/code). Every element that can be a link is one — Cmd+click your working directory, git branch, or quota directly from the statusline.

![preview](preview.svg)

## Features

- **OSC-8 hyperlinks** — path opens in Finder, branch opens on GitHub, quota opens `claude.ai/settings/usage`
- **2-line layout** — directory · branch · model on line 1; context window · quota · cost on line 2
- **Catppuccin Mocha** palette with semantic colors — green → yellow → red as limits fill
- **Smart truncation** — long paths show last 2 segments, branch names cap at 25 chars
- **Quota tracking** — 5-hour and 7-day usage with time-until-reset, fetched live and cached
- **Context window** — percentage + max size, with ⚠️ / 🚨 warnings at 60% and 80%

## Requirements

- [Ghostty](https://ghostty.org) — OSC-8 and 24-bit color support required
- [Claude Code](https://claude.ai/code)
- `jq`, `git`, `curl`
- macOS (uses BSD `date` and `security` keychain for OAuth token)

## Installation

```sh
curl -o ~/.claude/statusline.sh https://raw.githubusercontent.com/aaaaa/clickline/main/statusline.sh
chmod +x ~/.claude/statusline.sh
```

Then add to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash /Users/YOU/.claude/statusline.sh"
  }
}
```

Replace `/Users/YOU` with your actual home directory path.

## What's clickable

| Element | Destination |
|---|---|
| Working directory | `file://` — opens in Finder / default file handler |
| Git branch | `https://github.com/owner/repo/tree/branch` |
| 5h quota % | `https://claude.ai/settings/usage` |
| 7d quota % | `https://claude.ai/settings/usage` |
| "Quota —" (when data unavailable) | `https://claude.ai/settings/usage` |

OSC-8 links require a terminal that supports them. Ghostty, iTerm2, and WezTerm all do. Cmd+click (macOS) or Ctrl+click activates the link.

## Layout

```
my-app/src · feat/dark-mode │ Claude Sonnet 4.6
35%/200K │ 85% (2h3m) · 61% (3d5h) │ $4
```

**Line 1:** `path · branch │ model [thinking] [│ VIM mode] [│ agent name]`

**Line 2:** `ctx%/maxK │ 5h% (reset) · 7d% (reset) │ $cost`

- Context colors: green < 50%, yellow < 75%, red ≥ 75%
- Quota colors: green < 50%, yellow < 75%, red ≥ 75%
- Cost is ceiling-rounded to whole dollars
- VIM mode and agent name only appear when active

## Quota authentication

Quota data is fetched from the Anthropic API using your Claude Code OAuth token from the macOS keychain. It's cached for 60 seconds with stale-while-revalidate so it never blocks rendering.

If quota shows `—`, try signing out and back in to Claude Code to refresh token scopes:

```
/logout
/login
```

## License

MIT
