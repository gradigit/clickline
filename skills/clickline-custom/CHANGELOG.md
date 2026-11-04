# Changelog

## 1.1.0 — 2026-11-04

- Status indicators (`cmd` / `condition`) are saved to the global file only; repo `.clickline` items are static links, since the statusline no longer runs commands from repo files

## 1.0.0 — 2026-02-20

- Initial release
- Interactive workflow for adding service links, status indicators, and custom items
- Support for both global (`~/.claude/clickline-custom.json`) and per-repo (`.clickline`) storage
- Service link presets for Railway, Vercel, Netlify, Supabase, Neon, Render, Fly.io
- Automatic LAYOUT update in `clickline.conf`
