---
description: Configure clickable service links (backend, frontend, database) for this repository's clickline statusline. Use when you want to add or update links to Railway, Vercel, Netlify, Supabase, Neon, Render, Fly.io, or any other service dashboard.
---

Configure per-repository service links for the clickline statusline. Links appear on line 1 next to the model name and open in the browser on Cmd+click (requires Ghostty or iTerm2 with OSC-8 support).

## Steps

1. **Check existing config** — read `$PWD/.clickline` if it exists and show the user their current services.

2. **Ask what to configure** — use AskUserQuestion with `multiSelect: true` to let the user pick which services they want, then ask for each URL. Sensible choices:
   - Backend (Railway, Render, Fly.io, …)
   - Frontend (Vercel, Netlify, Cloudflare Pages, …)
   - Database (Supabase, Neon, PlanetScale, …)
   - Custom (any label + URL the user provides)

3. **Write `.clickline`** in `$PWD` with the collected services. Preserve any existing services the user did not explicitly change.

4. **Confirm** — tell the user their links are saved and will appear in the statusline immediately.

## Config file format

`.clickline` lives in the repository root:

```json
{
  "services": [
    {"label": "backend", "url": "https://myapp.up.railway.app"},
    {"label": "frontend", "url": "https://myapp.vercel.app"},
    {"label": "db", "url": "https://supabase.com/dashboard/project/abc123"}
  ]
}
```

- `label` — short display name shown in the statusline (keep it under ~10 chars)
- `url` — full URL opened on Cmd+click

Services render in list order — put the one you click most often first.

## Common URL patterns

| Service | URL |
|---------|-----|
| Railway | `https://<app>.up.railway.app` or the Railway dashboard deployment URL |
| Vercel | `https://<app>.vercel.app` or `https://vercel.com/<team>/<project>` |
| Netlify | `https://<app>.netlify.app` or the Netlify site dashboard URL |
| Supabase | `https://supabase.com/dashboard/project/<ref>` |
| Neon | `https://console.neon.tech/app/projects/<id>` |
| Render | `https://dashboard.render.com/web/<id>` |
| Fly.io | `https://fly.io/apps/<app>` |
| PlanetScale | `https://app.planetscale.com/<org>/<db>` |

## Tips

- To remove a service, run `/service-links` again and omit it
- Add `.clickline` to `.gitignore` if your dashboard URLs are sensitive or team-specific
- Labels are shortened in narrow terminals — keep them concise
