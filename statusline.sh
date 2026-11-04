#!/bin/bash
# clickline — config-driven statusline for Claude Code
# https://github.com/gradigit/clickline

# ── Config ───────────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
source "$HOME/.claude/clickline.conf" 2>/dev/null

input=$(cat)

# ── Extract all variables (single jq call) ───────────────────────────────────
eval "$(echo "$input" | jq -r '
  @sh "model=\(.model.display_name // "—")",
  @sh "model_id=\(.model.id // "—")",
  @sh "dir=\(.workspace.current_dir // "")",
  @sh "used=\(.context_window.used_percentage // "")",
  @sh "ctx_size=\(.context_window.context_window_size // 200000)",
  @sh "cost=\(.cost.total_cost_usd // 0)",
  @sh "duration_ms=\(.cost.total_duration_ms // 0)",
  @sh "vim_mode=\(.vim.mode // "")",
  @sh "agent_name=\(.agent.name // "")",
  @sh "thinking_enabled=\(.model.thinking_enabled // .thinking.enabled // "")",
  @sh "reasoning_effort=\(.model.reasoning_effort // .effort.level // "")",
  @sh "transcript_path=\(.transcript_path // "")",
  @sh "ver=\(.version // "")",
  @sh "in_5h_used=\(if .rate_limits.five_hour.used_percentage != null then (.rate_limits.five_hour.used_percentage | floor) else "" end)",
  @sh "in_5h_reset=\(.rate_limits.five_hour.resets_at // "")",
  @sh "in_7d_used=\(if .rate_limits.seven_day.used_percentage != null then (.rate_limits.seven_day.used_percentage | floor) else "" end)",
  @sh "in_7d_reset=\(.rate_limits.seven_day.resets_at // "")",
  @sh "in_pr_number=\(.pr.number // "")",
  @sh "in_pr_url=\(.pr.url // "")",
  @sh "pc_warm=\(if .prompt_cache then (.prompt_cache.warm | tostring) else "" end)",
  @sh "pc_expires=\(.prompt_cache.expires_at // "")",
  @sh "pc_ttl=\(.prompt_cache.ttl // "")",
  @sh "pc_hit=\(if .prompt_cache.hit_ratio != null then (.prompt_cache.hit_ratio * 100 | floor) else "" end)"
' 2>/dev/null)"

# Fallbacks
[ -z "$model" ]       && model="—"
[ -z "$dir" ]         && dir="$PWD"
[ -z "$cost" ]        && cost=0
[ -z "$duration_ms" ] && duration_ms=0

# ── Thinking level ────────────────────────────────────────────────────────────
thinking=""
if [ -n "$reasoning_effort" ]; then
  thinking="$reasoning_effort"
elif [ "$thinking_enabled" = "true" ]; then
  thinking="on"
else
  case "$model_id" in
    *think*|*extended*) thinking="extended" ;;
  esac
fi

# ── Timestamp ─────────────────────────────────────────────────────────────────
now_epoch=$(date +%s)

# Directory for cache files (overridable for tests)
CL_TMP="${CLICKLINE_TMP_DIR:-/tmp}"

# ── Quota data ────────────────────────────────────────────────────────────────
# Preferred source: Claude Code's statusline input (.rate_limits, present after
# the session's first API response on Claude.ai plans) — no network call.
# Fallback for older Claude Code versions: the OAuth usage endpoint, cached
# and throttled.
QUOTA_CACHE="$CL_TMP/.claude-usage-cache"
QUOTA_TTL=${QUOTA_CACHE_TTL:-60}
five_hr_used=""
five_hr_reset=""
seven_day_used=""
seven_day_reset=""

# Each session only knows the quota as of its own last API response, so idle
# sessions lag behind. Usage within a window only grows, so share the highest
# value seen for the same window (same resets_at) across all sessions.
# Usage: _quota_share <tag> <used> <resets_at>   → prints "<used> <resets_at>"
_quota_share() {
  local f="$CL_TMP/.clickline-quota-$1" used="$2" reset="$3" s_reset=0 s_used=0
  case "$reset" in ''|*[!0-9]*) printf '%s %s' "$used" "$reset"; return ;; esac
  [ -f "$f" ] && read -r s_reset s_used < "$f"
  case "$s_reset" in ''|*[!0-9]*) s_reset=0 ;; esac
  case "$s_used" in ''|*[!0-9]*) s_used=0 ;; esac
  if [ "$s_reset" -gt "$reset" ]; then
    used=$s_used; reset=$s_reset        # this session's data predates the current window
  elif [ "$s_reset" -eq "$reset" ] && [ "$s_used" -gt "$used" ]; then
    used=$s_used                         # another session has seen newer usage
  fi
  if [ "$reset" != "$s_reset" ] || [ "$used" != "$s_used" ]; then
    printf '%s %s\n' "$reset" "$used" > "$f.$$" && mv -f "$f.$$" "$f"
  fi
  printf '%s %s' "$used" "$reset"
}

if [ "${SHOW_QUOTA:-true}" = "true" ] && { [ -n "$in_5h_used" ] || [ -n "$in_7d_used" ]; }; then
  # Either window may be absent (e.g. plans without a 5-hour limit)
  [ -n "$in_5h_used" ] && read -r five_hr_used five_hr_reset <<< "$(_quota_share 5h "$in_5h_used" "$in_5h_reset")"
  [ -n "$in_7d_used" ] && read -r seven_day_used seven_day_reset <<< "$(_quota_share 7d "$in_7d_used" "$in_7d_reset")"
elif [ "${SHOW_QUOTA:-true}" = "true" ]; then
  QUOTA_ATTEMPT="$CL_TMP/.claude-usage-attempt"
  _fetch_usage() {
    # Throttle shared by all sessions ("<last attempt> <consecutive failures>"):
    # QUOTA_TTL after a success, doubling per failure up to 1h, so a failing
    # endpoint (e.g. HTTP 429) is never hammered by every session's refresh.
    local last_attempt=0 fails=0
    [ -f "$QUOTA_ATTEMPT" ] && read -r last_attempt fails < "$QUOTA_ATTEMPT"
    case "$last_attempt" in ''|*[!0-9]*) last_attempt=0 ;; esac
    case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
    local wait=$(( QUOTA_TTL << (fails > 6 ? 6 : fails) ))
    [ "$wait" -gt 3600 ] && wait=3600
    [ $(( now_epoch - last_attempt )) -lt "$wait" ] && return 1
    echo "$now_epoch $(( fails + 1 ))" > "$QUOTA_ATTEMPT"   # a failure until it succeeds
    local token raw
    # macOS: Keychain
    raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
    if [ -n "$raw" ]; then
      token=$(echo "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    fi
    # Linux: credentials file
    if [ -z "$token" ] && [ -f "$HOME/.claude/.credentials.json" ]; then
      token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
    [ -z "$token" ] && return 1
    local resp
    resp=$(curl -s --max-time 3 \
      -H "Authorization: Bearer $token" \
      -H "anthropic-beta: oauth-2025-04-20" \
      "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
    [ -z "$resp" ] && return 1
    # Either window may be null (e.g. no 5-hour limit). Requiring .five_hour
    # here used to reject every valid response, so the cache never refreshed
    # and every render refetched.
    echo "$resp" | jq -e '.five_hour // .seven_day' >/dev/null 2>&1 || return 1
    echo "$now_epoch $resp" > "$QUOTA_CACHE.$$" && mv -f "$QUOTA_CACHE.$$" "$QUOTA_CACHE"
    echo "$now_epoch 0" > "$QUOTA_ATTEMPT"
    echo "$resp"
  }

  _get_usage() {
    if [ -f "$QUOTA_CACHE" ]; then
      local cached_epoch age
      cached_epoch=$(cut -d' ' -f1 "$QUOTA_CACHE")
      case "$cached_epoch" in ''|*[!0-9]*) cached_epoch=0 ;; esac
      age=$(( now_epoch - cached_epoch ))
      if [ "$age" -lt "$QUOTA_TTL" ]; then
        cut -d' ' -f2- "$QUOTA_CACHE"
        return 0
      fi
      ( _fetch_usage >/dev/null 2>&1 & )
      # Serve stale data only while it's plausibly current; past
      # QUOTA_MAX_AGE show "Quota —" rather than misleading numbers.
      [ "$age" -lt "${QUOTA_MAX_AGE:-900}" ] && cut -d' ' -f2- "$QUOTA_CACHE"
      return 0
    fi
    _fetch_usage
  }

  usage_json=$(_get_usage 2>/dev/null)
  if [ -n "$usage_json" ]; then
    eval "$(echo "$usage_json" | jq -r '
      @sh "five_hr_used=\(if .five_hour.utilization then (.five_hour.utilization | floor) else "" end)",
      @sh "five_hr_reset=\(.five_hour.resets_at // "")",
      @sh "seven_day_used=\(if .seven_day.utilization then (.seven_day.utilization | floor) else "" end)",
      @sh "seven_day_reset=\(.seven_day.resets_at // "")"
    ' 2>/dev/null)"
  fi
fi

# ── Portable ISO 8601 → epoch ─────────────────────────────────────────────────
_iso_to_epoch() {
  local cleaned="$1"
  # GNU date (Linux) then BSD date (macOS)
  date -d "$cleaned" "+%s" 2>/dev/null \
    || date -jf "%Y-%m-%dT%H:%M:%S%z" "$cleaned" "+%s" 2>/dev/null
}

# Reset timestamp (ISO 8601 from the API, or epoch seconds from stdin) → epoch
_reset_epoch() {
  case "$1" in
    '') return ;;
    *[!0-9]*) _iso_to_epoch "$(echo "$1" | sed 's/\.[0-9]*//; s/Z$/+0000/; s/:\([0-9][0-9]\)$/\1/')" ;;
    *) echo "$1" ;;
  esac
}

# ── Format helpers ────────────────────────────────────────────────────────────
# Both print nothing once the reset time has passed (the window started over).
fmt_reset() {
  local reset_epoch
  reset_epoch=$(_reset_epoch "$1")
  [ -z "$reset_epoch" ] && return
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -le 0 ] && return
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  [ "$h" -gt 0 ] && { printf "%dh%dm" "$h" "$m"; return; }
  printf "%dm" "$m"
}

fmt_reset_days() {
  local reset_epoch
  reset_epoch=$(_reset_epoch "$1")
  [ -z "$reset_epoch" ] && return
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -le 0 ] && return
  local days=$(( diff / 86400 ))
  local hours=$(( (diff % 86400) / 3600 ))
  [ "$days" -gt 0 ] && { printf "%dd%dh" "$days" "$hours"; return; }
  printf "%dh" "$hours"
}

fmt_tokens() {
  local n=${1:-0}
  [ -z "$n" ] && n=0
  if   [ "$n" -ge 1000000 ]; then printf "%dM" "$(( n / 1000000 ))"
  elif [ "$n" -ge 1000 ];    then printf "%dK" "$(( n / 1000 ))"
  else                            printf "%d"  "$n"
  fi
}

# ── Pre-format values ─────────────────────────────────────────────────────────
f_cost="\$$(echo "$cost" | awk '{c=int($1); if ($1>c) c++; print c}')"
f_ctx_size=$(fmt_tokens "$ctx_size")

# ── Short path (last PATH_SEGMENTS segments) ──────────────────────────────────
_ps=${PATH_SEGMENTS:-2}
short_dir=$(echo "$dir" | awk -F/ -v n="$_ps" '
  NF <= n + 1 { print; next }
  {
    r = ""
    for (i = NF - n + 1; i <= NF; i++) r = (r == "") ? $i : r "/" $i
    print r
  }
')

# ── md5 helper (portable: macOS md5 / Linux md5sum) ──────────────────────────
_md5() { printf '%s' "$1" | md5 2>/dev/null || printf '%s' "$1" | md5sum 2>/dev/null | cut -d' ' -f1; }

# ── Git info ──────────────────────────────────────────────────────────────────
github_remote_url() {
  local remote="$1"
  case "$remote" in
    git@github.com:*)       printf 'https://github.com/%s' "${remote#git@github.com:}" | sed 's|\.git$||' ;;
    ssh://git@github.com/*) printf 'https://github.com/%s' "${remote#ssh://git@github.com/}" | sed 's|\.git$||' ;;
    https://github.com/*)   printf '%s' "$remote" | sed 's|\.git$||' ;;
    https://*@github.com/*) printf 'https://github.com/%s' "${remote#*@github.com/}" | sed 's|\.git$||' ;;
  esac
}

github_repo_path() {
  local url="$1"
  [ -n "$url" ] && printf '%s' "${url#https://github.com/}"
}

git_branch_full=""
git_branch_ref=""
git_ref_url=""
repo_path=""
github_branch_url=""
git_root=$(git -C "$dir" rev-parse --show-toplevel 2>/dev/null)

if [ -n "$git_root" ]; then
  git_branch_full=$(git -C "$dir" branch --show-current 2>/dev/null)
  if [ -n "$git_branch_full" ]; then
    git_branch_ref="$git_branch_full"
    _git_upstream=$(git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)
    if [ -n "$_git_upstream" ]; then
      _git_remote_name=${_git_upstream%%/*}
      _git_remote_branch=${_git_upstream#*/}
      if [ -n "$_git_remote_name" ] && [ "$_git_remote_branch" != "$_git_upstream" ]; then
        _git_remote=$(git -C "$dir" config --get "remote.$_git_remote_name.url" 2>/dev/null)
        _github_remote=$(github_remote_url "$_git_remote")
        if [ -n "$_github_remote" ]; then
          repo_path=$(github_repo_path "$_github_remote")
          git_ref_url="$_git_remote_branch"
          github_branch_url="${_github_remote}/tree/${git_ref_url}"
        fi
      fi
    fi
  else
    git_ref_url=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
    [ -n "$git_ref_url" ] && git_branch_ref="detached@$git_ref_url"
    _git_remote=$(git -C "$dir" config --get remote.origin.url 2>/dev/null)
    _github_remote=$(github_remote_url "$_git_remote")
    if [ -n "$_github_remote" ]; then
      repo_path=$(github_repo_path "$_github_remote")
      github_branch_url="${_github_remote}/tree/${git_ref_url}"
    fi
  fi

  if [ -z "$repo_path" ]; then
    _git_remote=$(git -C "$dir" config --get remote.origin.url 2>/dev/null)
    _github_remote=$(github_remote_url "$_git_remote")
    [ -n "$_github_remote" ] && repo_path=$(github_repo_path "$_github_remote")
  fi
fi

git_branch="$git_branch_ref"
git_branch_placeholder="${git_branch_full:-$git_branch_ref}"
git_branch_remote_ref="${git_ref_url:-$git_branch_full}"
_max_b=${BRANCH_MAX_CHARS:-25}
if [ -n "$git_branch" ] && [ "${#git_branch}" -gt "$_max_b" ]; then
  git_branch="${git_branch:0:$(( _max_b - 1 ))}…"
fi

repo_hash=$(_md5 "${git_root:-$dir}")

# ── Custom items (merged: repo-local .clickline overrides global) ────────────
# Repo-local items are static (label/link/color) only. cmd and condition are
# eval'd as shell, so honoring them from a .clickline would let any repo you
# open run commands through your statusline; they only work from the global
# file.
_custom_merged=""
_cg=""; _cr=""
[ -f "$HOME/.claude/clickline-custom.json" ] && _cg=$(cat "$HOME/.claude/clickline-custom.json" 2>/dev/null)
_cl_root="${git_root:-$dir}"
[ -f "$_cl_root/.clickline" ] && _cr=$(jq -c 'map_values(del(.cmd, .condition))' "$_cl_root/.clickline" 2>/dev/null)
if [ -n "$_cg" ] && [ -n "$_cr" ]; then
  _custom_merged=$(printf '%s\n%s' "$_cg" "$_cr" | jq -s '.[0] * .[1]' 2>/dev/null)
elif [ -n "$_cr" ]; then
  _custom_merged="$_cr"
elif [ -n "$_cg" ]; then
  _custom_merged="$_cg"
fi

default_branch=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|origin/||')

# ── Dirty count (tracked files modified and/or staged, each counted once) ────
# --no-optional-locks: never take index.lock, so this can't collide with git
# commands running in the session at the same moment.
dirty_count=""
if [ "${SHOW_DIRTY:-true}" = "true" ] && [ -n "$git_root" ]; then
  dirty_count=$(git --no-optional-locks -C "$dir" status --porcelain --untracked-files=no 2>/dev/null | wc -l | tr -d ' ')
fi

# ── Ahead / behind remote ─────────────────────────────────────────────────────
ahead=0
behind=0
if [ "${SHOW_AHEAD_BEHIND:-false}" = "true" ] && [ -n "$git_root" ]; then
  if git -C "$dir" rev-parse '@{u}' >/dev/null 2>&1; then
    read -r ahead behind <<< "$(git -C "$dir" rev-list --left-right --count HEAD...@{u} 2>/dev/null)"
    ahead=${ahead:-0}
    behind=${behind:-0}
  fi
fi

# ── Commit hash ───────────────────────────────────────────────────────────────
commit_short=""
commit_full=""
if [ "${SHOW_COMMIT:-false}" = "true" ] && [ -n "$git_root" ]; then
  commit_short=$(git -C "$dir" rev-parse --short HEAD 2>/dev/null)
  commit_full=$(git -C "$dir" rev-parse HEAD 2>/dev/null)
fi

# ── Cache write helper (atomic: readers never see a half-written file) ───────
_cache_write() { local t="$1.$$.$RANDOM"; printf '%s %s\n' "$(date +%s)" "$2" > "$t" && mv -f "$t" "$1"; }

# ── PR link ───────────────────────────────────────────────────────────────────
# Claude Code tracks the branch's PR itself (gh, with backoff + ETag caching)
# and passes it as .pr — use that when present. Otherwise (no PR, or an older
# Claude Code) fall back to a cached `gh pr view`, at most once per
# PR_CACHE_TTL per repo, never blocking the render.
pr_number=""
pr_url=""
pr_new_url=""
PR_CACHE="$CL_TMP/.clickline-pr-${repo_hash}"

if [ "${SHOW_PR:-true}" = "true" ] && [ -n "$in_pr_number" ]; then
  pr_number="$in_pr_number"
  pr_url="$in_pr_url"
elif [ "${SHOW_PR:-true}" = "true" ] \
   && [ -n "$git_branch_full" ] \
   && [ "$git_branch_full" != "$default_branch" ] \
   && command -v gh >/dev/null 2>&1 \
   && [ -n "$repo_path" ]; then

  _pr_data=""; _pr_age=999999
  if [ -f "$PR_CACHE" ]; then
    _cache_ts=$(cut -d' ' -f1 "$PR_CACHE")
    case "$_cache_ts" in ''|*[!0-9]*) _cache_ts=0 ;; esac
    _pr_data=$(cut -d' ' -f2- "$PR_CACHE")
    _pr_age=$(( now_epoch - _cache_ts ))
  fi
  if [ "$_pr_age" -gt "${PR_CACHE_TTL:-60}" ]; then
    # Re-stamp before fetching so concurrent renders don't fetch too ("null" =
    # not looked up yet). `gh pr view` exits 1 when the branch has no PR:
    # record that as {}, or the cache never refreshes and every render calls
    # GitHub again.
    _cache_write "$PR_CACHE" "${_pr_data:-null}"
    ( _out=$(cd "$dir" && gh pr view --repo "$repo_path" --json url,number 2>/dev/null | jq -c '.' 2>/dev/null)
      _cache_write "$PR_CACHE" "${_out:-"{}"}" ) &
  fi
  eval "$(echo "$_pr_data" | jq -r '@sh "pr_number=\(.number // "")", @sh "pr_url=\(.url // "")"' 2>/dev/null)"

  # "New PR" only once a lookup has confirmed there's no open PR
  if [ -z "$pr_number" ] && [ "$_pr_data" = "{}" ]; then
    _branch_enc=$(jq -rn --arg b "$git_branch_remote_ref" '$b | @uri' 2>/dev/null)
    _branch_enc="${_branch_enc//%2F//}"
    pr_new_url="https://github.com/${repo_path}/compare/${_branch_enc:-$git_branch_remote_ref}?expand=1"
  fi
fi

# ── CI status (async cache — never blocks render) ─────────────────────────────
ci_status=""
ci_conclusion=""
ci_url=""
CI_CACHE="$CL_TMP/.clickline-ci-${repo_hash}-$(_md5 "${git_branch_remote_ref:-nobranch}")"

if [ "${SHOW_CI:-false}" = "true" ] \
   && [ -n "$git_branch_remote_ref" ] \
   && [ -n "$repo_path" ] \
   && command -v gh >/dev/null 2>&1; then

  _ci_data="[]"; _ci_age=999999
  if [ -f "$CI_CACHE" ]; then
    _cache_ts=$(cut -d' ' -f1 "$CI_CACHE")
    case "$_cache_ts" in ''|*[!0-9]*) _cache_ts=0 ;; esac
    _ci_data=$(cut -d' ' -f2- "$CI_CACHE")
    _ci_age=$(( now_epoch - _cache_ts ))
  fi
  if [ "$_ci_age" -gt "${CI_CACHE_TTL:-30}" ]; then
    # Re-stamp before fetching, so concurrent renders don't fetch too and a
    # failed gh call waits a full TTL instead of retrying on every render.
    _cache_write "$CI_CACHE" "$_ci_data"
    ( _out=$(cd "$dir" && gh run list --repo "$repo_path" --branch "$git_branch_remote_ref" --limit 1 \
          --json status,conclusion,url 2>/dev/null | jq -c '.' 2>/dev/null)
      [ -n "$_out" ] && _cache_write "$CI_CACHE" "$_out" ) &
  fi
  eval "$(echo "$_ci_data" | jq -r '
    .[0] // empty |
    @sh "ci_status=\(.status // "")",
    @sh "ci_conclusion=\(.conclusion // "")",
    @sh "ci_url=\(.url // "")"
  ' 2>/dev/null)"
fi

# ── Path URI ──────────────────────────────────────────────────────────────────
case "${PATH_LINK_TARGET:-finder}" in
  vscode) path_uri="vscode://file/${dir}" ;;
  cursor) path_uri="cursor://file/${dir}" ;;
  none)   path_uri="" ;;
  *)      path_uri="file://${dir}" ;;
esac

# ═══════════════════════════════════════════════════════════════════════════════
# PALETTE — themed 24-bit true color (10 semantic slots)
# ═══════════════════════════════════════════════════════════════════════════════
RST=$'\033[0m'
BOLD=$'\033[1m'
ITALIC=$'\033[3m'

_load_theme() {
  case "${THEME:-catppuccin-mocha}" in
    catppuccin-mocha)
      c_label=$'\033[38;2;108;112;134m'    # #6c7086
      c_sep=$'\033[38;2;88;91;112m'        # #585b70
      c_dim=$'\033[38;2;69;71;90m'         # #45475a
      c_sapphire=$'\033[38;2;116;199;236m' # #74c7ec
      c_lavender=$'\033[38;2;180;190;254m' # #b4befe
      c_mauve=$'\033[38;2;203;166;247m'    # #cba6f7
      c_gold=$'\033[38;2;249;226;175m'     # #f9e2af
      c_green=$'\033[38;2;166;227;161m'    # #a6e3a1
      c_peach=$'\033[38;2;250;179;135m'    # #fab387
      c_red=$'\033[38;2;243;139;168m'      # #f38ba8
      ;;
    catppuccin-frappe)
      c_label=$'\033[38;2;131;139;167m'    # #838ba7
      c_sep=$'\033[38;2;115;121;148m'      # #737994
      c_dim=$'\033[38;2;98;104;128m'       # #626880
      c_sapphire=$'\033[38;2;133;193;220m' # #85c1dc
      c_lavender=$'\033[38;2;186;187;241m' # #babbf1
      c_mauve=$'\033[38;2;202;158;230m'    # #ca9ee6
      c_gold=$'\033[38;2;229;200;144m'     # #e5c890
      c_green=$'\033[38;2;166;209;137m'    # #a6d189
      c_peach=$'\033[38;2;239;159;118m'    # #ef9f76
      c_red=$'\033[38;2;231;130;132m'      # #e78284
      ;;
    catppuccin-latte)
      c_label=$'\033[38;2;140;143;161m'    # #8c8fa1
      c_sep=$'\033[38;2;172;176;190m'      # #acb0be
      c_dim=$'\033[38;2;188;192;204m'      # #bcc0cc
      c_sapphire=$'\033[38;2;32;159;181m'  # #209fb5
      c_lavender=$'\033[38;2;114;135;253m' # #7287fd
      c_mauve=$'\033[38;2;136;57;239m'     # #8839ef
      c_gold=$'\033[38;2;223;142;29m'      # #df8e1d
      c_green=$'\033[38;2;64;160;43m'      # #40a02b
      c_peach=$'\033[38;2;254;100;11m'     # #fe640b
      c_red=$'\033[38;2;210;15;57m'        # #d20f39
      ;;
    dracula)
      c_label=$'\033[38;2;98;114;164m'     # #6272a4
      c_sep=$'\033[38;2;68;71;90m'         # #44475a
      c_dim=$'\033[38;2;68;71;90m'         # #44475a
      c_sapphire=$'\033[38;2;139;233;253m' # #8be9fd
      c_lavender=$'\033[38;2;189;147;249m' # #bd93f9
      c_mauve=$'\033[38;2;255;121;198m'    # #ff79c6
      c_gold=$'\033[38;2;241;250;140m'     # #f1fa8c
      c_green=$'\033[38;2;80;250;123m'     # #50fa7b
      c_peach=$'\033[38;2;255;184;108m'    # #ffb86c
      c_red=$'\033[38;2;255;85;85m'        # #ff5555
      ;;
    tokyo-night)
      c_label=$'\033[38;2;86;95;137m'      # #565f89
      c_sep=$'\033[38;2;54;63;95m'         # #363f5f
      c_dim=$'\033[38;2;54;63;95m'         # #363f5f
      c_sapphire=$'\033[38;2;125;207;255m' # #7dcfff
      c_lavender=$'\033[38;2;122;162;247m' # #7aa2f7
      c_mauve=$'\033[38;2;187;154;247m'    # #bb9af7
      c_gold=$'\033[38;2;224;175;104m'     # #e0af68
      c_green=$'\033[38;2;158;206;106m'    # #9ece6a
      c_peach=$'\033[38;2;255;158;100m'    # #ff9e64
      c_red=$'\033[38;2;247;118;142m'      # #f7768e
      ;;
    gruvbox-dark)
      c_label=$'\033[38;2;146;131;116m'    # #928374
      c_sep=$'\033[38;2;80;73;69m'         # #504945
      c_dim=$'\033[38;2;80;73;69m'         # #504945
      c_sapphire=$'\033[38;2;131;165;152m' # #83a598
      c_lavender=$'\033[38;2;211;134;155m' # #d3869b
      c_mauve=$'\033[38;2;211;134;155m'    # #d3869b
      c_gold=$'\033[38;2;250;189;47m'      # #fabd2f
      c_green=$'\033[38;2;184;187;38m'     # #b8bb26
      c_peach=$'\033[38;2;254;128;25m'     # #fe8019
      c_red=$'\033[38;2;251;73;52m'        # #fb4934
      ;;
    nord)
      c_label=$'\033[38;2;76;86;106m'      # #4c566a
      c_sep=$'\033[38;2;67;76;94m'         # #434c5e
      c_dim=$'\033[38;2;59;66;82m'         # #3b4252
      c_sapphire=$'\033[38;2;136;192;208m' # #88c0d0
      c_lavender=$'\033[38;2;129;161;193m' # #81a1c1
      c_mauve=$'\033[38;2;180;142;173m'    # #b48ead
      c_gold=$'\033[38;2;235;203;139m'     # #ebcb8b
      c_green=$'\033[38;2;163;190;140m'    # #a3be8c
      c_peach=$'\033[38;2;208;135;112m'    # #d08770
      c_red=$'\033[38;2;191;97;106m'       # #bf616a
      ;;
    solarized-dark)
      c_label=$'\033[38;2;88;110;117m'     # #586e75
      c_sep=$'\033[38;2;7;54;66m'          # #073642
      c_dim=$'\033[38;2;7;54;66m'          # #073642
      c_sapphire=$'\033[38;2;38;139;210m'  # #268bd2
      c_lavender=$'\033[38;2;108;113;196m' # #6c71c4
      c_mauve=$'\033[38;2;211;54;130m'     # #d33682
      c_gold=$'\033[38;2;181;137;0m'       # #b58900
      c_green=$'\033[38;2;133;153;0m'      # #859900
      c_peach=$'\033[38;2;203;75;22m'      # #cb4b16
      c_red=$'\033[38;2;220;50;47m'        # #dc322f
      ;;
    one-dark)
      c_label=$'\033[38;2;92;99;112m'      # #5c6370
      c_sep=$'\033[38;2;59;64;72m'         # #3b4048
      c_dim=$'\033[38;2;59;64;72m'         # #3b4048
      c_sapphire=$'\033[38;2;86;182;194m'  # #56b6c2
      c_lavender=$'\033[38;2;97;175;239m'  # #61afef
      c_mauve=$'\033[38;2;198;120;221m'    # #c678dd
      c_gold=$'\033[38;2;229;192;123m'     # #e5c07b
      c_green=$'\033[38;2;152;195;121m'    # #98c379
      c_peach=$'\033[38;2;209;154;102m'    # #d19a66
      c_red=$'\033[38;2;224;108;117m'      # #e06c75
      ;;
    rose-pine)
      c_label=$'\033[38;2;110;106;134m'    # #6e6a86
      c_sep=$'\033[38;2;57;53;82m'         # #393552
      c_dim=$'\033[38;2;57;53;82m'         # #393552
      c_sapphire=$'\033[38;2;156;207;216m' # #9ccfd8
      c_lavender=$'\033[38;2;196;167;231m' # #c4a7e7
      c_mauve=$'\033[38;2;235;111;146m'    # #eb6f92
      c_gold=$'\033[38;2;246;193;119m'     # #f6c177
      c_green=$'\033[38;2;49;116;143m'     # #31748f
      c_peach=$'\033[38;2;234;154;151m'    # #ea9a97
      c_red=$'\033[38;2;235;111;146m'      # #eb6f92
      ;;
    *)
      # Unknown theme — fall back to catppuccin-mocha
      THEME=catppuccin-mocha
      _load_theme
      return
      ;;
  esac
}
_load_theme

status_color() {
  local pct=$1
  if   [ "$pct" -lt 50 ]; then printf '%s' "$c_green"
  elif [ "$pct" -lt 75 ]; then printf '%s' "$c_peach"
  else                          printf '%s' "$c_red"
  fi
}

CTX_COLOR=$c_green
[ -n "$used" ] && CTX_COLOR=$(status_color "$used")

# ── OSC-8 hyperlinks ──────────────────────────────────────────────────────────
osc_link() { printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$1" "$2"; }
osc_url()  { printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"; }

S="${c_sep} │ ${RST}"
DOT="${c_sep} · ${RST}"

exec 2>/dev/null

# Cache cleanup (non-blocking, files older than 7 days): at most once a day,
# top level of /tmp only. The caches live there; recursing walked every
# directory under /tmp on every render.
_CLEANUP_STAMP="$CL_TMP/.clickline-cleanup-stamp"
_last_cleanup=0
[ -f "$_CLEANUP_STAMP" ] && read -r _last_cleanup < "$_CLEANUP_STAMP"
case "$_last_cleanup" in ''|*[!0-9]*) _last_cleanup=0 ;; esac
if [ $(( now_epoch - _last_cleanup )) -ge 86400 ]; then
  echo "$now_epoch" > "$_CLEANUP_STAMP"
  find "$CL_TMP" -maxdepth 1 -name '.clickline-*' -mtime +7 -delete 2>/dev/null &
fi

# Leading blank line
[ "${LEADING_NEWLINE:-false}" = "true" ] && printf '\n'

# ── CI symbol derivation ──────────────────────────────────────────────────────
ci_symbol=""
if [ -n "$ci_status" ]; then
  case "$ci_status" in
    completed)
      case "$ci_conclusion" in
        success)           ci_symbol="${c_green}✓${RST}" ;;
        failure|cancelled) ci_symbol="${c_red}✗${RST}" ;;
        *)                 ci_symbol="${c_peach}?${RST}" ;;
      esac ;;
    in_progress|queued|waiting) ci_symbol="${c_dim}⋯${RST}" ;;
    *)                          ci_symbol="${c_dim}?${RST}" ;;
  esac
fi

# ── Element renderer ──────────────────────────────────────────────────────────
# Called in a subshell via $(render_element name) — prints element to stdout,
# prints nothing (returns early) when the element is disabled or has no data.
render_element() {
  local _e="$1"
  case "$_e" in
    path)
      if [ -n "$path_uri" ]; then
        printf '%s' "${c_sapphire}"; osc_url "$path_uri" "$short_dir"; printf '%s' "${RST}"
      else
        printf '%s%s%s' "${c_sapphire}" "$short_dir" "${RST}"
      fi ;;
    branch)
      [ "${SHOW_BRANCH:-true}" != "true" ] && return
      [ -z "$git_branch" ] && return
      printf '%s' "${c_green}"
      if [ -n "$github_branch_url" ]; then
        osc_url "$github_branch_url" "$git_branch"
      else
        printf '%s' "$git_branch"
      fi
      printf '%s' "${RST}"
      if [ "${SHOW_DIRTY:-true}" = "true" ] && [ -n "$dirty_count" ] && [ "$dirty_count" -gt 0 ]; then
        printf '%s·%s%s' "${c_peach}" "$dirty_count" "${RST}"
      fi
      if [ "${SHOW_AHEAD_BEHIND:-false}" = "true" ]; then
        [ "${ahead:-0}" -gt 0 ]  && printf ' %s↑%s%s' "${c_green}" "$ahead"  "${RST}"
        [ "${behind:-0}" -gt 0 ] && printf ' %s↓%s%s' "${c_peach}" "$behind" "${RST}"
      fi ;;
    commit)
      [ "${SHOW_COMMIT:-false}" != "true" ] && return
      [ -z "$commit_short" ] && return
      printf '%s' "${c_dim}"
      if [ -n "$commit_full" ] && [ -n "$repo_path" ]; then
        osc_url "https://github.com/${repo_path}/commit/${commit_full}" "$commit_short"
      else
        printf '%s' "$commit_short"
      fi
      printf '%s' "${RST}" ;;
    pr)
      [ "${SHOW_PR:-true}" != "true" ] && return
      if [ -n "$pr_number" ] && [ -n "$pr_url" ]; then
        printf '%s' "${c_lavender}"; osc_url "$pr_url" "#${pr_number}"; printf '%s' "${RST}"
      elif [ -n "$pr_new_url" ]; then
        printf '%s' "${c_dim}"; osc_url "$pr_new_url" "New PR"; printf '%s' "${RST}"
      else
        return
      fi ;;
    ci)
      [ "${SHOW_CI:-false}" != "true" ] && return
      [ -z "$ci_symbol" ] && return
      if [ -n "$ci_url" ]; then
        printf '\033]8;;%s\033\\' "$ci_url"; printf '%s' "$ci_symbol"; printf '\033]8;;\033\\'
      else
        printf '%s' "$ci_symbol"
      fi ;;
    model)
      [ "${SHOW_MODEL:-true}" != "true" ] && return
      printf '%s%s' "${c_lavender}" "${BOLD}"
      osc_url "https://docs.anthropic.com/en/docs/about-claude/models/overview" "$model"
      printf '%s' "${RST}"
      [ -n "$thinking" ] && printf ' %s%s%s%s' "${c_mauve}" "${ITALIC}" "$thinking" "${RST}" ;;
    version)
      [ "${SHOW_VERSION:-false}" != "true" ] && return
      [ -z "$ver" ] && return
      printf '%s' "${c_dim}"; osc_url "https://github.com/anthropics/claude-code/releases" "v${ver}"; printf '%s' "${RST}" ;;
    vim)
      [ -z "$vim_mode" ] && return
      printf '%s%sVIM %s%s%s' "${c_mauve}" "" "${BOLD}" "$vim_mode" "${RST}" ;;
    agent)
      [ -z "$agent_name" ] && return
      printf '%s%s%s' "${c_lavender}" "$agent_name" "${RST}" ;;
    context)
      [ "${SHOW_CONTEXT:-true}" != "true" ] && return
      if [ -n "$used" ]; then
        local _cw="" _cb=""
        [ "$used" -ge 80 ] && _cw=" 🚨"
        [ "$used" -ge 60 ] && [ "$used" -lt 80 ] && _cw=" ⚠️"
        [ "$used" -ge 60 ] && _cb="${BOLD}"
        printf '%s%s%s%%%s%s/%s%s%s' "${c_gold}" "$_cb" "$used" "${RST}" "${c_dim}" "$f_ctx_size" "${RST}" "$_cw"
      else
        printf '%s—%s' "${c_dim}" "${RST}"
      fi ;;
    quota)
      [ "${SHOW_QUOTA:-true}" != "true" ] && return
      if [ -z "$five_hr_used" ] && [ -z "$seven_day_used" ]; then
        printf '%s' "${c_label}"; osc_url "https://claude.ai/settings/usage" "Quota —"; printf '%s' "${RST}"
        return
      fi
      # Each window renders independently (either may be absent), as %
      # remaining; the reset hint (h/m vs d/h) tells the windows apart.
      if [ -n "$five_hr_used" ]; then
        local _5u=${five_hr_used%%.*}; [ -z "$_5u" ] && _5u=0
        local _5e; _5e=$(_reset_epoch "$five_hr_reset")
        [ -n "$_5e" ] && [ "$_5e" -le "$now_epoch" ] && _5u=0   # window started over
        local _FC; _FC=$(status_color "$_5u")
        local _5r; _5r=$(fmt_reset "$five_hr_reset")
        printf '%s%s' "$_FC" "${BOLD}"; osc_url "https://claude.ai/settings/usage" "$(( 100 - _5u ))%"; printf '%s' "${RST}"
        [ -n "$_5r" ] && printf ' %s(%s)%s' "${c_dim}" "$_5r" "${RST}"
      fi
      if [ -n "$seven_day_used" ]; then
        [ -n "$five_hr_used" ] && printf '%s' "${DOT}"
        local _7u=${seven_day_used%%.*}; [ -z "$_7u" ] && _7u=0
        local _7e; _7e=$(_reset_epoch "$seven_day_reset")
        [ -n "$_7e" ] && [ "$_7e" -le "$now_epoch" ] && _7u=0   # window started over
        local _SC; _SC=$(status_color "$_7u")
        local _7r; _7r=$(fmt_reset_days "$seven_day_reset")
        printf '%s%s' "$_SC" "${BOLD}"; osc_url "https://claude.ai/settings/usage" "$(( 100 - _7u ))%"; printf '%s' "${RST}"
        [ -n "$_7r" ] && printf ' %s(%s)%s' "${c_dim}" "$_7r" "${RST}"
      fi ;;
    cache)
      # Prompt cache: time until it goes cold, plus the session's cache hit
      # rate. A cold cache means the next message re-sends the whole context
      # uncached, which costs more quota.
      [ "${SHOW_CACHE:-true}" != "true" ] && return
      [ -z "$pc_warm" ] && return   # no API request yet this session
      local _left=0
      [ "$pc_warm" = "true" ] && [ -n "$pc_expires" ] && _left=$(( ${pc_expires%%.*} - now_epoch ))
      if [ "$_left" -gt 0 ]; then
        local _ttl_s=300
        case "$pc_ttl" in *h) _ttl_s=$(( ${pc_ttl%h} * 3600 )) ;; *m) _ttl_s=$(( ${pc_ttl%m} * 60 )) ;; esac
        local _cc="$c_green"; [ $(( _left * 5 )) -lt "$_ttl_s" ] && _cc="$c_peach"   # <20% of TTL left
        local _lt; if [ "$_left" -ge 60 ]; then _lt="$(( _left / 60 ))m"; else _lt="${_left}s"; fi
        printf '%scache %s%s%s%s' "${c_label}" "$_cc" "${BOLD}" "$_lt" "${RST}"
      else
        printf '%scache %scold%s' "${c_label}" "$c_red" "${RST}"
      fi
      [ -n "$pc_hit" ] && printf ' %s%s%% hit%s' "${c_dim}" "$pc_hit" "${RST}" ;;
    cost)
      [ "${SHOW_COST:-true}" != "true" ] && return
      printf '%s%s' "${c_gold}" "${BOLD}"
      # file:// links only work when the terminal runs on this machine;
      # PATH_LINK_TARGET=none turns them off (e.g. over ssh/mosh)
      if [ -n "$transcript_path" ] && [ "${PATH_LINK_TARGET:-finder}" != "none" ]; then
        osc_url "file://${transcript_path}" "$f_cost"
      else
        printf '%s' "$f_cost"
      fi
      printf '%s' "${RST}" ;;
    custom_*)
      # Custom items from merged global + repo-local sources
      local _cname="${_e#custom_}"
      [ -z "$_custom_merged" ] && return
      local _def; _def=$(printf '%s' "$_custom_merged" | jq -r --arg n "$_cname" '.[$n] // empty' 2>/dev/null)
      [ -z "$_def" ] && return
      # Check condition (if set, shell command must exit 0)
      local _cond; _cond=$(printf '%s' "$_def" | jq -r '.condition // ""' 2>/dev/null)
      if [ -n "$_cond" ]; then
        eval "$_cond" >/dev/null 2>&1 || return
      fi
      # Get label: from cmd output (cached) or static label
      local _cmd; _cmd=$(printf '%s' "$_def" | jq -r '.cmd // ""' 2>/dev/null)
      local _label
      if [ -n "$_cmd" ]; then
        local _ttl; _ttl=$(printf '%s' "$_def" | jq -r '.cache_ttl // 30' 2>/dev/null)
        local _ccache="$CL_TMP/.clickline-custom-${_cname}"
        if [ -f "$_ccache" ]; then
          local _cage=$(( now_epoch - $(cut -d' ' -f1 "$_ccache") ))
          if [ "$_cage" -lt "${_ttl:-30}" ]; then
            _label=$(cut -d' ' -f2- "$_ccache")
          else
            ( _out=$(eval "$_cmd" 2>/dev/null | head -c 80)
              printf '%s %s\n' "$(date +%s)" "$_out" > "$_ccache" ) &
            _label=$(cut -d' ' -f2- "$_ccache")
          fi
        else
          _label=$(eval "$_cmd" 2>/dev/null | head -c 80 | tr -d '\n')
          printf '%s %s\n' "$now_epoch" "$_label" > "$_ccache"
        fi
      else
        _label=$(printf '%s' "$_def" | jq -r '.label // ""' 2>/dev/null)
      fi
      [ -z "$_label" ] && return
      # Get color
      local _ccolor; _ccolor=$(printf '%s' "$_def" | jq -r '.color // "dim"' 2>/dev/null)
      local _cc
      case "$_ccolor" in
        sapphire) _cc="$c_sapphire" ;; lavender) _cc="$c_lavender" ;;
        mauve)    _cc="$c_mauve"    ;; gold)     _cc="$c_gold"     ;;
        green)    _cc="$c_green"    ;; peach)    _cc="$c_peach"    ;;
        red)      _cc="$c_red"      ;; *)        _cc="$c_dim"      ;;
      esac
      # Get link
      local _link; _link=$(printf '%s' "$_def" | jq -r '.link // ""' 2>/dev/null)
      _link="${_link//\{dir\}/$dir}"
      _link="${_link//\{branch\}/$git_branch_placeholder}"
      printf '%s' "$_cc"
      if [ -n "$_link" ]; then
        osc_url "$_link" "$_label"
      else
        printf '%s' "$_label"
      fi
      printf '%s' "${RST}" ;;
  esac
}

# ── Layout rendering ───────────────────────────────────────────────────────────
# LAYOUT is a space-separated list of element names with | as a line separator.
# Elements are rendered in order; disabled/empty elements are skipped cleanly.
_DEFAULT_LAYOUT="path branch commit pr ci model version vim agent | context cache quota cost"
IFS=' ' read -ra _tokens <<< "${LAYOUT:-$_DEFAULT_LAYOUT}"

_first=true
_prev=""
for _tok in "${_tokens[@]}"; do
  if [ "$_tok" = "|" ]; then
    printf '\n'
    _first=true
    _prev=""
    continue
  fi
  _out=$(render_element "$_tok")
  [ -z "$_out" ] && continue
  if [ "$_first" = "false" ]; then
    if [ "$_tok" = "branch" ] && [ "$_prev" = "path" ]; then
      printf '%s' "$DOT"
    elif [[ "$_tok" == custom_* ]] && [[ "$_prev" == custom_* ]]; then
      printf '%s' "$DOT"
    else
      printf '%s' "$S"
    fi
  fi
  printf '%s' "$_out"
  _first=false
  _prev="$_tok"
done
printf '\n'
