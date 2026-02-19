---
name: clickline-custom
description: Adds or manages custom statusline items for clickline. Handles both global
  items (~/.claude/clickline-custom.json) and per-repo items (.clickline). Activates
  when user wants to "add a statusline item", "add service links", "add a custom element",
  "configure clickline items", or mentions adding deployment links (Railway, Vercel,
  Supabase, Neon, Netlify, Render, Fly.io) to the statusline. Do NOT use when user
  asks to install clickline, change layout order, modify colors, or remove items — direct
  them to install.sh or the TUI configurator instead.
metadata:
  version: "1.0.0"
---

# /clickline-custom

Add or manage custom statusline items for clickline.

## Workflow

- [ ] 1. Check existing files (`~/.claude/clickline-custom.json` and `.clickline` at git root or cwd)
- [ ] 2. Show current items if any exist
- [ ] 3. Ask what kind of item (service link / status indicator / custom)
- [ ] 4. Ask where to save (this repo `.clickline` / global `clickline-custom.json`)
- [ ] 5. Collect details based on item type
- [ ] 6. Write to appropriate file, merging with existing entries
- [ ] 7. Append `custom_<name>` to LAYOUT in `~/.claude/clickline.conf`
- [ ] 8. Confirm with preview of how it will appear

## Step details

### Step 1–2: Discovery

Read both files. Display a summary if items exist:

```
Global items (~/.claude/clickline-custom.json):
  - kube-ctx: ⎈ k8s-prod (green, cmd: kubectl config current-context)

Repo items (.clickline):
  - backend: backend (sapphire, link: https://app.railway.app)
```

### Step 3: Item type

Ask using AskUserQuestion with three options:
- **Service link** — clickable link to a deployment dashboard
- **Status indicator** — dynamic value from a shell command
- **Custom** — static label with optional link and color

### Step 5: Collect details

For **service links**, offer presets and ask for app name/project ID:

| Service  | URL pattern                                    |
|----------|------------------------------------------------|
| Railway  | `https://<app>.up.railway.app`                 |
| Vercel   | `https://<app>.vercel.app`                     |
| Netlify  | `https://<app>.netlify.app`                    |
| Supabase | `https://supabase.com/dashboard/project/<ref>` |
| Neon     | `https://console.neon.tech/app/projects/<id>`  |
| Render   | `https://dashboard.render.com/web/<id>`        |
| Fly.io   | `https://fly.io/apps/<app>`                    |

For **status indicators**, collect: `cmd`, `cache_ttl` (default 30), `condition` (optional), `color`.

For **custom**, collect: `label`, `link` (optional, supports `{dir}` and `{branch}`), `color`.

### Step 6: Write

Merge with existing JSON (don't overwrite). Keys are stored without the `custom_` prefix.

### Step 7: Update LAYOUT

Read `~/.claude/clickline.conf`, find `LAYOUT=`, append `custom_<name>` before the first `|` if not already present.

## Item JSON format

```json
{
  "backend": {
    "label": "backend",
    "color": "sapphire",
    "link": "https://my-app.up.railway.app"
  }
}
```

| Field       | Required | Description                                           |
|-------------|----------|-------------------------------------------------------|
| `label`     | Yes      | Static display text (ignored if `cmd` is set)         |
| `color`     | No       | sapphire, lavender, mauve, gold, green, peach, red, dim (default: dim) |
| `link`      | No       | Clickable URL. Supports `{dir}` and `{branch}`       |
| `cmd`       | No       | Shell command — output replaces label                 |
| `cache_ttl` | No       | Seconds to cache cmd output (default: 30)             |
| `condition` | No       | Shell command — item hidden if exit code != 0         |

## Example

**Input:** "Add a Railway link for my backend"

**Output:**

1. Asks: app name? → "my-api"
2. Asks: save to repo or global? → "This repo"
3. Writes `.clickline`:
   ```json
   {
     "backend": {
       "label": "backend",
       "color": "sapphire",
       "link": "https://my-api.up.railway.app"
     }
   }
   ```
4. Updates `clickline.conf` LAYOUT: `path branch custom_backend pr ci model ...`
5. Confirms: "Added 'backend' to `.clickline` — will appear as `backend` in sapphire, linking to Railway."

## Notes

- Adjacent custom items render with dot separators (` · `) instead of pipes (` │ `).
- Repo items override global items with the same name.
- Add `.clickline` to `.gitignore` if URLs are sensitive.
- The TUI (`python3 ~/.claude/clickline-configure.py`) also supports `c` (custom) and `r` (repo item).

## Self-Evolution

Update when:
1. New deployment service becomes popular → add to presets table
2. User corrects URL pattern → fix preset
3. clickline JSON format changes → update field table

Current version: 1.0.0
