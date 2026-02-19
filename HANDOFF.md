# Handoff — clickline

**Date:** 2026-02-20
**Branch:** main
**Last commit:** 73ad57d

## What happened this session

Implemented the full plan from PR #1 review: repo-local `.clickline` support, TUI repo items, and `/clickline-custom` skill. Then did docs sync, release prep, and shipped v1.0.0.

### Major changes
1. **`statusline.sh`** — pre-read merge of global + repo custom items via `jq -s`, dot separators for adjacent custom items
2. **`configure.py`** — `repo_items`/`repo_path` fields, `[repo]` tags in library, `+ Repo item` button, `r` keybinding, split save, `custom_` prefix normalization bug fix
3. **`/clickline-custom` skill** — new skill at `skills/clickline-custom/` with service link presets, interactive workflow
4. **`install.sh`** — `read || true` fix, skill install step
5. **`README.md`** — service link presets, configurator screenshot, TUI hotkeys, acknowledgments, skill section
6. **`CLAUDE.md`** — new file with key files, commands, architecture, gotchas, code style

### Bugs found and fixed
- Global custom items missing `custom_` prefix in TUI (968266f)
- Spinner `fold -w3` broken on macOS — should be `fold -w1` (18ad4f1)
- README had fabricated `~/.claude/statusline-install.sh` path
- README missing `LEADING_NEWLINE`, `p`/`?` hotkeys, emoji warnings

### Released
- **v1.0.0** — first GitHub release with full feature list
- Repo description and topics updated
- PR #1 closed with credit to @guzus

## Current state
- All changes committed and pushed to main
- Release v1.0.0 live at https://github.com/gradigit/clickline/releases/tag/v1.0.0
- No open PRs, no pending work
- Installed copies at `~/.claude/` updated with latest code

## First steps for next session
1. Read `CLAUDE.md` for project context
2. Check GitHub issues for any new reports
3. Consider: regenerate `preview.svg` to reflect current theme/layout
