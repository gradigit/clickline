# Parse `clickline.conf` instead of sourcing it

## Summary

`statusline.sh` used to `source "$HOME/.claude/clickline.conf"`, which runs the config file
as a shell script on every statusline render. This replaces it with a small builtin-only
parser that reads `KEY=value` pairs against an allowlist of known settings, so
`clickline.conf` is treated as data rather than code.

Along the way this also fixes a latent bug in the shipped default config: `LAYOUT` was
unquoted, so `bash` parsed the `|` as a pipeline and `source` never actually set `LAYOUT`
at all.

## What changed

- `statusline.sh` — `source` replaced with `_load_conf`, a fork-free parser with a key allowlist.
- `clickline.conf.default`, `README.md` — `LAYOUT` quoted; config-value semantics documented.
- `CHANGELOG.md` — new `Unreleased` section, including the breaking change described below.
- `test/conf-parse.sh` — new test covering comment/quote interaction, literal values, and unknown keys.

## Breaking change

`source` expanded `$VAR`, `$(command)` and backticks inside config values. The parser stores
them literally. In practice this affects self-referential settings:

```bash
LAYOUT="$LAYOUT custom_x"   # used to append; now stored verbatim
```

Users need to write the full value out instead. This is documented in `README.md` and
`CHANGELOG.md`.

## Performance

The first version of this parser stripped comments with `printf '%s' "$_line" | sed ...`,
which forks twice per config line. That is a real regression on a script that runs on every
prompt. It now uses parameter expansion only.

Measured on macOS with `/bin/bash` 3.2.57 against a 29-line `clickline.conf`:

| `_load_conf` implementation | per call |
|---|---|
| `source` (previous behavior) | 0.10 ms |
| parser using `printf \| sed` | 194.11 ms |
| parser using parameter expansion (this PR) | 1.17 ms |

End-to-end render, interleaved A/B, 25 reps each, network calls stubbed:

| build | median | vs `main` |
|---|---|---|
| `main` (`source`) | 371.10 ms | — |
| parser with `sed` | 592.37 ms | +221.27 ms (+59.6%) |
| parser with parameter expansion (this PR) | 370.28 ms | -0.82 ms (-0.2%) |

## Verification

- `bash -n statusline.sh` — clean
- `shellcheck --severity=error statusline.sh test/*.sh` — clean
- `test/git-worktree.sh` — 8/8 pass
- `test/conf-parse.sh` — 8/8 pass; verified to fail against the pre-fix parser
- Live render against a real repo with a committed `.clickline` — all elements render,
  including its four custom items, with no stderr output. Note that this `.clickline`
  contains only `label`/`color`/`link` fields, so it exercises the custom-item path but not
  the `eval` path described below.

---

# ⚠️ Out of scope: pre-existing RCE via repo-supplied `.clickline`

**This is NOT fixed by this PR and is not a regression introduced by it. It is a
pre-existing vulnerability in `main` that should be tracked as its own issue.**

It is recorded here because it is strictly more serious than the issue this PR closes:
`clickline.conf` is user-local, whereas `.clickline` is **repo-supplied and arrives via
`git clone`**.

## Vector

`statusline.sh` merges two JSON sources into `_custom_merged`:

- `~/.claude/clickline-custom.json` (user-local)
- `<repo root>/.clickline` (**committed to the repository**)

When rendering a `custom_*` layout element, the `.condition` and `.cmd` fields of that JSON
are passed to `eval` — three sites, at `statusline.sh:709`, `:722`, `:727` on this branch
(`:701`, `:714`, `:719` on `main`):

```bash
_cond=$(printf '%s' "$_def" | jq -r '.condition // ""' 2>/dev/null)
if [ -n "$_cond" ]; then
  eval "$_cond" >/dev/null 2>&1 || return
fi
...
_label=$(eval "$_cmd" 2>/dev/null | head -c 80 | tr -d '\n')
```

Cloning a repository and opening it in Claude Code is enough to run whatever the repository
author put in those fields. No prompt, no confirmation, and the command runs on every render
(subject to `cache_ttl`).

## Proof

A git-tracked `.clickline` committed to a scratch repo:

```json
{"pwned": {"label": "x", "cmd": "touch /tmp/PROOF_CMD_RAN; printf owned"}}
```

Rendering the statusline with that repo as `workspace.current_dir` created
`/tmp/PROOF_CMD_RAN` and printed `owned` into the statusline. The file was tracked by git
(`git ls-files` → `.clickline`), i.e. it would have arrived through a normal `git clone`.

## Precondition (important — this is narrower than "any clone")

The `custom_*` branch is only reached if the **victim's own** `LAYOUT` contains a matching
`custom_<name>` token. With `LAYOUT='path branch'` the payload above does **not** execute.
So this is not unconditional code execution on clone.

That precondition is weak in practice:

1. `skills/clickline-custom/SKILL.md` step 7 instructs users to append `custom_<name>` to
   `LAYOUT` — so any user who has ever added a custom item has such tokens.
2. The documented service-link presets use highly guessable, generic names: `backend`,
   `frontend`, `db`, `website`, `railway`, `vercel`, `netlify`, `neon`. A malicious repo
   shipping `.clickline` with `{"backend": {"cmd": "..."}}` hits every user who followed the
   project's own skill.
3. Repo-local `.clickline` **overrides** the global file in the merge (`.[0] * .[1]`), so a
   hostile repo can hijack a `custom_backend` token the user added for their own benign
   global config.
4. The commit in this PR that widened lookup to `.["custom_" + $n]` widens the match surface
   slightly, since both `backend` and `custom_backend` keys now resolve.

## Suggested fix (for the separate issue)

Treat repo-supplied `.clickline` as untrusted:

- Drop `eval` for the `.cmd` path and execute via an argv array with no shell
  (`_out=$("${_argv[@]}")`), taking `cmd` as a JSON array of arguments. This removes shell
  metacharacter injection outright and covers the documented use cases
  (`kubectl config current-context`, `node -v`).
- Ignore `condition` and `cmd` entirely when they come from a repo-local `.clickline`,
  honoring them only from the user-local `~/.claude/clickline-custom.json`. Repo-local
  entries would keep `label`, `color` and `link`, which is what real-world `.clickline`
  files (service dashboard links) actually use.
- If repo-local commands must stay supported, gate them behind an explicit trust list in
  `~/.claude/` recording approved repo paths plus a hash of the `.clickline`, and re-prompt
  whenever the file changes.

Option 2 is the smallest change that closes the vector and does not break any documented
usage.

## Note on commit `9d5e56e`

That commit's message says "A config file is data, not code." That claim is accurate for
`clickline.conf`, which is what the commit changes, but it should not be read as covering
`.clickline` — that file is still `eval`'d, as described above. Flagging it explicitly so
the statement is not mistaken for a project-wide guarantee.
