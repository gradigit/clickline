# clickline — AI Agent Install Guide

This file tells Claude Code (or any AI coding agent) how to install and configure clickline when a user pastes the GitHub link or asks to install it.

**You MUST use `AskUserQuestion` with `preview` fields throughout this flow.** Do not skip the interactive steps. Do not write config without asking the user first.

## Prerequisites

Before starting, check and install required dependencies:

```bash
# Required — install any that are missing
for dep in jq git curl; do
  command -v "$dep" >/dev/null 2>&1 || echo "MISSING: $dep"
done
```

If any are missing, offer to install them with the available package manager:
```bash
# macOS
brew install jq git curl
# Debian/Ubuntu
sudo apt-get install -y jq git curl
# Fedora
sudo dnf install -y jq git curl
```

Optional dependencies (inform the user but don't block install):
- `gh` — needed for PR and CI statusline features (install: `brew install gh` / `sudo apt install gh` / `sudo dnf install gh`, then `gh auth login`)
- `python3` + `textual` — needed for the TUI configurator (the installer auto-installs `uv` + `textual` if missing)

## Step 1: Download files

```bash
mkdir -p ~/.claude ~/.claude/skills/clickline-custom

curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/statusline.sh \
  -o ~/.claude/statusline.sh
chmod +x ~/.claude/statusline.sh

curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/configure.py \
  -o ~/.claude/clickline-configure.py

curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/skills/clickline-custom/SKILL.md \
  -o ~/.claude/skills/clickline-custom/SKILL.md
```

## Step 2: Update settings.json

Read `~/.claude/settings.json` (create if missing), then set:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash /Users/USERNAME/.claude/statusline.sh",
    "timeout": 5000
  }
}
```

Use `jq` to merge into existing settings — do not overwrite other keys:

```bash
jq --arg cmd "/bin/bash $HOME/.claude/statusline.sh" \
  '.statusLine = {"type":"command","command":$cmd,"timeout":5000}' \
  ~/.claude/settings.json > /tmp/settings.tmp && mv /tmp/settings.tmp ~/.claude/settings.json
```

If `~/.claude/settings.json` does not exist, create it with just the statusLine object.

## Step 3: Choose preset (AskUserQuestion with previews)

Ask the user to pick a preset using `AskUserQuestion`. Each option MUST have a `preview` field showing the ASCII layout mockup.

**Question:** "Which statusline preset do you want?"
**Header:** "Preset"
**multiSelect:** false

Options:

| Label | Description | Preview |
|---|---|---|
| Minimal | Just the essentials — path and model | `~/src\nSonnet 4.6` |
| Clean | Key info on two lines | `~/src · main·2 │ Sonnet 4.6\n45%/200K │ $4` |
| Standard (Recommended) | Git, model, and metrics | `~/src · main·2 │ #42 │ Sonnet 4.6\n45%/200K │ 82%·45% │ $4` |
| Developer | Full git details + CI | `~/src · main·2 │ abc1234 │ #42 │ ✓ │ Sonnet 4.6 │ VIM N\n45%/200K │ 82%·45% │ $4` |

Note: a 5th preset "Full" exists (adds version + agent to Developer) — if the user asks for everything, use that.

### Preset config values

```
Minimal:
  LAYOUT='path | model'
  SHOW_BRANCH=false SHOW_PR=false SHOW_CI=false SHOW_CONTEXT=false
  SHOW_QUOTA=false SHOW_COST=false SHOW_MODEL=true SHOW_COMMIT=false
  SHOW_VERSION=false SHOW_DIRTY=true SHOW_AHEAD_BEHIND=false

Clean:
  LAYOUT='path branch model | context cost'
  SHOW_BRANCH=true SHOW_PR=false SHOW_CI=false SHOW_CONTEXT=true
  SHOW_QUOTA=false SHOW_COST=true SHOW_MODEL=true SHOW_COMMIT=false
  SHOW_VERSION=false SHOW_DIRTY=true SHOW_AHEAD_BEHIND=false

Standard:
  LAYOUT='path branch pr model | context quota cost'
  SHOW_BRANCH=true SHOW_PR=true SHOW_CI=false SHOW_CONTEXT=true
  SHOW_QUOTA=true SHOW_COST=true SHOW_MODEL=true SHOW_COMMIT=false
  SHOW_VERSION=false SHOW_DIRTY=true SHOW_AHEAD_BEHIND=false

Developer:
  LAYOUT='path branch commit pr ci model vim | context quota cost'
  SHOW_BRANCH=true SHOW_PR=true SHOW_CI=true SHOW_CONTEXT=true
  SHOW_QUOTA=true SHOW_COST=true SHOW_MODEL=true SHOW_COMMIT=true
  SHOW_VERSION=false SHOW_DIRTY=true SHOW_AHEAD_BEHIND=true

Full:
  LAYOUT='path branch commit pr ci model version vim agent | context quota cost'
  SHOW_BRANCH=true SHOW_PR=true SHOW_CI=true SHOW_CONTEXT=true
  SHOW_QUOTA=true SHOW_COST=true SHOW_MODEL=true SHOW_COMMIT=true
  SHOW_VERSION=true SHOW_DIRTY=true SHOW_AHEAD_BEHIND=true
```

## Step 4: Choose theme (AskUserQuestion with previews)

Ask the user to pick a color theme. Show 4 options at a time (AskUserQuestion supports max 4 options). Default to the first group unless the user asks to see more.

**Question:** "Which color theme?"
**Header:** "Theme"
**multiSelect:** false

First group (most popular):

| Label | Description | Preview |
|---|---|---|
| catppuccin-mocha (Recommended) | Pastel dark — soft and easy on the eyes | `Palette: sapphire lavender mauve gold green peach\nStyle: Warm pastels on dark background\n\n  ~/src · main·2 │ #42 │ Sonnet 4.6\n  45%/200K │ 82%·45% │ $4` |
| dracula | High contrast dark — bold and vibrant | `Palette: cyan purple pink yellow green orange\nStyle: Vivid neons on dark background\n\n  ~/src · main·2 │ #42 │ Sonnet 4.6\n  45%/200K │ 82%·45% │ $4` |
| tokyo-night | Cool blue dark — calm and focused | `Palette: blue indigo purple amber green orange\nStyle: Cool blues on dark background\n\n  ~/src · main·2 │ #42 │ Sonnet 4.6\n  45%/200K │ 82%·45% │ $4` |
| More themes... | See all 10 themes | `Available:\n  catppuccin-frappe  Pastel mid-tone\n  catppuccin-latte   Pastel light\n  gruvbox-dark       Warm retro\n  nord               Arctic blue\n  solarized-dark     Classic low-contrast\n  one-dark           Atom-inspired\n  rose-pine          Soft elegant` |

If the user selects "More themes...", ask again with the remaining themes as options.

All 10 theme names: `catppuccin-mocha`, `catppuccin-frappe`, `catppuccin-latte`, `dracula`, `tokyo-night`, `gruvbox-dark`, `nord`, `solarized-dark`, `one-dark`, `rose-pine`.

## Step 5: Choose layout arrangement (AskUserQuestion with previews)

**Only ask this if the user chose Standard, Developer, or Full preset** (Minimal and Clean have fixed layouts).

**Question:** "How should the statusline be arranged?"
**Header:** "Layout"
**multiSelect:** false

| Label | Description | Preview |
|---|---|---|
| Two lines (Recommended) | Git and model on top, metrics on bottom | `Line 1: ~/src · main·2 │ #42 │ Sonnet 4.6\nLine 2: 45%/200K │ 82%·45% │ $4` |
| Compact | Everything on one line | `Line 1: ~/src · main·2 │ #42 │ Sonnet 4.6 │ 45%/200K │ 82%·45% │ $4` |
| Flipped | Metrics on top, git and model on bottom | `Line 1: 45%/200K │ 82%·45% │ $4\nLine 2: ~/src · main·2 │ #42 │ Sonnet 4.6` |

Update the LAYOUT value based on selection:
- **Two lines:** use `|` between git/model and metrics groups (this is the preset default)
- **Compact:** remove all `|` separators — everything on one line
- **Flipped:** swap the two groups around the `|`

## Step 6: Path click target (AskUserQuestion)

**Question:** "What should Cmd+click on the directory path open?"
**Header:** "Path target"
**multiSelect:** false

| Label | Description |
|---|---|
| Finder (Recommended) | Opens the directory in Finder (macOS) or file manager (Linux) |
| VS Code | Opens in VS Code (`vscode://file/...`) |
| Cursor | Opens in Cursor (`cursor://file/...`) |
| Nothing | Path is displayed but not clickable |

Config key: `PATH_LINK_TARGET=finder|vscode|cursor|none`

## Step 7: Write config

Write `~/.claude/clickline.conf` with all values from the selections above. Use this template:

```bash
cat > ~/.claude/clickline.conf << 'CONF'
# clickline config — generated YYYY-MM-DD
# Run install.sh again to change settings, or ask Claude Code
# Changes take effect on the next Claude Code response

# -- Features --
SHOW_BRANCH=$SHOW_BRANCH
SHOW_DIRTY=$SHOW_DIRTY
SHOW_AHEAD_BEHIND=$SHOW_AHEAD_BEHIND
SHOW_COMMIT=$SHOW_COMMIT
SHOW_PR=$SHOW_PR
SHOW_CI=$SHOW_CI
SHOW_MODEL=$SHOW_MODEL
SHOW_VERSION=$SHOW_VERSION
SHOW_CONTEXT=$SHOW_CONTEXT
SHOW_QUOTA=$SHOW_QUOTA
SHOW_COST=$SHOW_COST
LEADING_NEWLINE=false
LAYOUT='$LAYOUT'

# -- Options --
BRANCH_MAX_CHARS=25
PATH_SEGMENTS=2
PATH_LINK_TARGET=$PATH_LINK_TARGET
PR_CACHE_TTL=60
CI_CACHE_TTL=30
QUOTA_CACHE_TTL=60
THEME=$THEME
CONF
```

Replace the `$VARIABLES` with actual values from the user's selections.

## Step 8: Confirm

Tell the user:
- The statusline will appear on their next Claude Code response
- They can reconfigure anytime by asking Claude Code or running `bash install.sh`
- If quota shows `—`, run `bash install.sh --quota` to troubleshoot
- If they want PR/CI features: install `gh` (`brew install gh` / `sudo apt install gh` / `sudo dnf install gh`) then `gh auth login`

## Updating an existing install

If `~/.claude/statusline.sh` already exists and `~/.claude/settings.json` already has a `statusLine.command` pointing to it, this is a reconfigure — not a fresh install.

- Skip steps 1-2 (files already in place)
- Read the existing `~/.claude/clickline.conf` to show current values as defaults
- Run steps 3-7 as normal, with current settings pre-selected where possible
- After writing config, also re-download `statusline.sh` to pick up any upstream fixes:
  ```bash
  curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/statusline.sh \
    -o ~/.claude/statusline.sh
  chmod +x ~/.claude/statusline.sh
  ```

## Element reference

These are the tokens used in LAYOUT and their SHOW_ flags:

| Token | Flag | What it shows |
|---|---|---|
| `path` | (always on) | Working directory (last 2 segments) |
| `branch` | `SHOW_BRANCH` | Git branch name, truncated to 25 chars |
| `commit` | `SHOW_COMMIT` | HEAD short hash |
| `pr` | `SHOW_PR` | Open PR number or "New PR" link |
| `ci` | `SHOW_CI` | GitHub Actions status |
| `model` | `SHOW_MODEL` | Active Claude model name |
| `version` | `SHOW_VERSION` | Claude Code version |
| `vim` | (auto) | Vim mode indicator (shown when vim mode active) |
| `agent` | (auto) | Agent indicator (shown when in agent context) |
| `context` | `SHOW_CONTEXT` | Context window usage percentage |
| `quota` | `SHOW_QUOTA` | 5-hour and 7-day quota usage |
| `cost` | `SHOW_COST` | Session cost in dollars |

Tokens with `(auto)` appear automatically when relevant — no flag needed.
Adjacent custom items (e.g. `custom_a custom_b`) render with dot separator (` · `), all other elements use pipe (` | `).
