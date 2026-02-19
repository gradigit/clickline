# clickline

## Key Files
- `statusline.sh` — main statusline script (bash), renders OSC-8 links
- `configure.py` — Textual TUI configurator (Python 3, requires `textual`)
- `install.sh` — installer + bash wizard fallback
- `clickline.conf.default` — default config template
- `skills/clickline-custom/SKILL.md` — custom item skill

## Commands
- `bash install.sh` — install or reconfigure
- `bash install.sh --quota` — troubleshoot quota display
- `uv run python3 -c "import ast; ast.parse(open('configure.py').read())"` — syntax check configure.py
- `bash -n statusline.sh` — syntax check statusline.sh

## Architecture
- Config-driven: `~/.claude/clickline.conf` controls all features, layout, theme
- Custom items: global `~/.claude/clickline-custom.json` + per-repo `.clickline` (merged via `jq -s '.[0] * .[1]'`)
- 10 color themes defined in `THEMES` dict in configure.py (lines 53-104)
- 5 presets defined in `PRESETS` dict in configure.py (lines 159-220)
- Adjacent custom items use dot separator (` · `), other elements use pipe (` │ `)

## Code Style
- Shell: bash with `set -euo pipefail`, BSD date/sed (macOS)
- Python: Python 3, Textual framework, dataclasses, type hints
- Config values: `UPPER_SNAKE_CASE` in conf, theme/color keys are `lowercase-hyphen`
- Custom item keys stored without `custom_` prefix in JSON, prefixed in LAYOUT
