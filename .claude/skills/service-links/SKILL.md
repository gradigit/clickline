---
name: service-links
description: Configures clickable service links (backend, frontend, database) for a repository's clickline statusline by writing a .clickline file. Activates when user wants to "add service links", "configure statusline links", "add deployment links", or mentions adding Railway, Vercel, Netlify, Supabase, Neon, or similar service URLs to the statusline. Do NOT use this skill when the user is asking about general statusline configuration or installing clickline itself.
license: MIT
metadata:
  version: "1.0.0"
  author: gradigit
  updated: "2026-02-19"
  category: tooling
  tags:
    - statusline
    - clickline
    - deployment
    - links
  triggers:
    - "service-links"
    - "add service links"
    - "configure statusline links"
    - "add deployment links"
    - "add backend link"
    - "add frontend link"
    - "add database link"
---

# Service Links

Writes a `.clickline` file in the repository root to add clickable service links to the clickline statusline. Each link appears on line 1 next to the model name and opens in the browser on Cmd+click.

## Workflow

```
- [ ] 1. Check for existing .clickline config
- [ ] 2. Ask user which services to configure
- [ ] 3. Collect URLs for each selected service
- [ ] 4. Write .clickline to repo root
- [ ] 5. Confirm and show result
```

## Step 1: Check Existing Config

Read `$PWD/.clickline` if it exists. If found, show the current services so the user knows what's already configured before making changes.

## Step 2: Ask Which Services

Use AskUserQuestion with `multiSelect: true`:

```json
{
  "questions": [{
    "question": "Which services do you want to add links for?",
    "header": "Services",
    "multiSelect": true,
    "options": [
      {"label": "Backend", "description": "Railway, Render, Fly.io, etc."},
      {"label": "Frontend", "description": "Vercel, Netlify, Cloudflare Pages, etc."},
      {"label": "Database", "description": "Supabase, Neon, PlanetScale, etc."},
      {"label": "Custom", "description": "Any label + URL you choose"}
    ]
  }]
}
```

## Step 3: Collect URLs

For each selected service, ask for:
- The URL (required)
- A custom label if they chose "Custom" (default labels: `backend`, `frontend`, `db`)

Ask all at once if 2+ services were selected to minimize back-and-forth.

## Step 4: Write .clickline

Create or overwrite `$PWD/.clickline`:

```json
{
  "services": [
    {"label": "backend", "url": "https://myapp.up.railway.app"},
    {"label": "frontend", "url": "https://myapp.vercel.app"},
    {"label": "db", "url": "https://supabase.com/dashboard/project/abc123"}
  ]
}
```

- Preserve any existing services the user did not explicitly change
- Services render in list order — put the most-clicked one first
- Keep labels under 10 chars (truncated in narrow terminals)

## Step 5: Confirm

Show the user what was written. If they already have clickline running, tell them the links will appear immediately on the next statusline render.

## Common Service URL Patterns

| Service | URL |
|---------|-----|
| Railway | `https://<app>.up.railway.app` or Railway dashboard URL |
| Vercel | `https://<app>.vercel.app` or `https://vercel.com/<team>/<project>` |
| Netlify | `https://<app>.netlify.app` or Netlify site dashboard URL |
| Supabase | `https://supabase.com/dashboard/project/<ref>` |
| Neon | `https://console.neon.tech/app/projects/<id>` |
| Render | `https://dashboard.render.com/web/<id>` |
| Fly.io | `https://fly.io/apps/<app>` |
| PlanetScale | `https://app.planetscale.com/<org>/<db>` |

## Example

**User:** `/service-links` after deploying to Railway + Vercel + Supabase

**Step 1** — No `.clickline` found.

**Step 2** — User selects Backend, Frontend, Database.

**Step 3** — User provides:
- Backend: `https://myapi.up.railway.app`
- Frontend: `https://myapp.vercel.app`
- Database: `https://supabase.com/dashboard/project/xyzabc`

**Step 4** — Writes `.clickline`:
```json
{
  "services": [
    {"label": "backend", "url": "https://myapi.up.railway.app"},
    {"label": "frontend", "url": "https://myapp.vercel.app"},
    {"label": "db", "url": "https://supabase.com/dashboard/project/xyzabc"}
  ]
}
```

**Step 5** — Confirms:
```
✓ .clickline written. Statusline now shows:
  … │ Claude Sonnet 4.6 │ backend · frontend · db

Cmd+click any label to open the dashboard.
Add .clickline to .gitignore if these URLs are team-specific.
```

## Common Pitfalls

| Pitfall | Prevention |
|---------|------------|
| Overwriting services user wanted to keep | Read existing `.clickline` first and preserve unchanged entries |
| Label too long | Warn if label exceeds 10 chars and suggest a shorter one |
| URL missing protocol | Validate URL starts with `https://` before writing |

## Self-Evolution

Update this skill when:
1. New service URL patterns emerge → add to the common patterns table
2. `.clickline` format changes → update the JSON schema in Step 4
3. User reports confusion → simplify the AskUserQuestion flow

Current version: 1.0.0. See [CHANGELOG.md](CHANGELOG.md) for history.
