#!/bin/bash

# Claude Code Statusline — Compact 2-line, Catppuccin Mocha palette
# Designed for Ghostty with 24-bit color support
input=$(cat)

# ── Extract all variables (single jq call) ──
eval "$(echo "$input" | jq -r '
  @sh "model=\(.model.display_name // "—")",
  @sh "model_id=\(.model.id // "—")",
  @sh "dir=\(.workspace.current_dir // "—")",
  @sh "used=\(.context_window.used_percentage // "")",
  @sh "ctx_size=\(.context_window.context_window_size // 200000)",
  @sh "cost=\(.cost.total_cost_usd // 0)",
  @sh "duration_ms=\(.cost.total_duration_ms // 0)",
  @sh "vim_mode=\(.vim.mode // "")",
  @sh "agent_name=\(.agent.name // "")",
  @sh "thinking_enabled=\(.model.thinking_enabled // "")",
  @sh "reasoning_effort=\(.model.reasoning_effort // "")"
' 2>/dev/null)"

# Fallbacks
[ -z "$model" ] && model="—"
[ -z "$dir" ] && dir="$PWD"
[ -z "$cost" ] && cost=0
[ -z "$duration_ms" ] && duration_ms=0

# ── Thinking level ──
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

# ── Session duration ──
now_epoch=$(date +%s)
if [ "$duration_ms" -gt 0 ]; then
  duration_s=$((duration_ms / 1000))
  hrs=$((duration_s / 3600))
  mins=$(( (duration_s % 3600) / 60 ))
  secs=$((duration_s % 60))
  if [ "$hrs" -gt 0 ]; then
    duration_human="${hrs}h ${mins}m"
  elif [ "$mins" -gt 0 ]; then
    duration_human="${mins}m ${secs}s"
  else
    duration_human="${secs}s"
  fi
else
  duration_human="0s"
fi

# ── Rate limit / usage quota (cached 60s) ──
CACHE_FILE="/tmp/.claude-usage-cache"
CACHE_TTL=60
five_hr_used=""
five_hr_reset=""
seven_day_used=""
seven_day_reset=""

fetch_usage() {
  local token
  token=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
  [ -z "$token" ] && return 1
  local resp
  resp=$(curl -s --max-time 3 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null)
  [ -z "$resp" ] && return 1
  echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1 || return 1
  echo "$now_epoch $resp" > "$CACHE_FILE"
  echo "$resp"
}

get_usage() {
  if [ -f "$CACHE_FILE" ]; then
    local cached_epoch
    cached_epoch=$(cut -d' ' -f1 "$CACHE_FILE")
    if [ $((now_epoch - cached_epoch)) -lt $CACHE_TTL ]; then
      cut -d' ' -f2- "$CACHE_FILE"
      return 0
    fi
    ( fetch_usage >/dev/null 2>&1 & )
    cut -d' ' -f2- "$CACHE_FILE"
    return 0
  fi
  fetch_usage
}

usage_json=$(get_usage 2>/dev/null)
if [ -n "$usage_json" ]; then
  eval "$(echo "$usage_json" | jq -r '
    @sh "five_hr_used=\(if .five_hour.utilization then (.five_hour.utilization | floor) else "" end)",
    @sh "five_hr_reset=\(.five_hour.resets_at // "")",
    @sh "seven_day_used=\(if .seven_day.utilization then (.seven_day.utilization | floor) else "" end)",
    @sh "seven_day_reset=\(.seven_day.resets_at // "")"
  ' 2>/dev/null)"
fi

# ── Format helpers ──
fmt_reset() {
  local reset_iso="$1"
  [ -z "$reset_iso" ] && return
  local cleaned
  cleaned=$(echo "$reset_iso" | sed 's/\.[0-9]*//; s/Z$/+0000/; s/:\([0-9][0-9]\)$/\1/')
  local reset_epoch
  reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$cleaned" "+%s" 2>/dev/null)
  [ -z "$reset_epoch" ] && return
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -le 0 ] && { printf "now"; return; }
  local h=$(( diff / 3600 ))
  local m=$(( (diff % 3600) / 60 ))
  if [ "$h" -gt 0 ]; then
    printf "%dh%dm" "$h" "$m"
  else
    printf "%dm" "$m"
  fi
}

fmt_reset_days() {
  local reset_iso="$1"
  [ -z "$reset_iso" ] && return
  local cleaned
  cleaned=$(echo "$reset_iso" | sed 's/\.[0-9]*//; s/Z$/+0000/; s/:\([0-9][0-9]\)$/\1/')
  local reset_epoch
  reset_epoch=$(date -jf "%Y-%m-%dT%H:%M:%S%z" "$cleaned" "+%s" 2>/dev/null)
  [ -z "$reset_epoch" ] && return
  local diff=$(( reset_epoch - now_epoch ))
  [ "$diff" -le 0 ] && { printf "0d"; return; }
  local days=$(( diff / 86400 ))
  local hours=$(( (diff % 86400) / 3600 ))
  if [ "$days" -gt 0 ]; then
    printf "%dd%dh" "$days" "$hours"
  else
    printf "%dh" "$hours"
  fi
}

fmt_tokens() {
  local n=${1:-0}
  [ -z "$n" ] && n=0
  if [ "$n" -ge 1000000 ]; then
    printf "%dM" "$((n / 1000000))"
  elif [ "$n" -ge 1000 ]; then
    printf "%dK" "$((n / 1000))"
  else
    printf "%d" "$n"
  fi
}

# Pre-format values
f_cost="\$$(echo "$cost" | awk '{c=int($1); if ($1>c) c++; print c}')"

# Context window tokens
if [ -n "$used" ] && [ "$used" -gt 0 ]; then
  ctx_tokens=$(( ctx_size * used / 100 ))
else
  ctx_tokens=0
fi
f_ctx_tokens=$(fmt_tokens "$ctx_tokens")
f_ctx_size=$(fmt_tokens "$ctx_size")

# ── Shorten path to last 2 segments ──
short_dir=$(echo "$dir" | awk -F/ '{if(NF<=2) print $0; else print $(NF-1)"/"$NF}')

# ── Git branch (truncate at 25 chars) + GitHub URL ──
git_branch=$(git -C "$dir" symbolic-ref --short HEAD 2>/dev/null)
max_branch=25
if [ -n "$git_branch" ] && [ ${#git_branch} -gt $max_branch ]; then
  git_branch="${git_branch:0:$((max_branch-1))}…"
fi
github_branch_url=""
if [ -n "$git_branch" ]; then
  git_remote=$(git -C "$dir" remote get-url origin 2>/dev/null)
  if [ -n "$git_remote" ]; then
    repo_path=$(echo "$git_remote" | sed 's|git@github.com:||; s|https://github.com/||; s|\.git$||')
    github_branch_url="https://github.com/${repo_path}/tree/${git_branch}"
  fi
fi

# ═══════════════════════════════════════════════════
# TRUE COLOR PALETTE — Catppuccin Mocha
# ═══════════════════════════════════════════════════
RST='\033[0m'
BOLD='\033[1m'
ITALIC='\033[3m'

c_label='\033[38;2;108;112;134m'     # #6c7086 — Overlay0
c_sep='\033[38;2;88;91;112m'         # #585b70 — Surface2
c_dim='\033[38;2;69;71;90m'          # #45475a — Surface1
c_subtext='\033[38;2;186;194;222m'   # #bac2de — Subtext1
c_sapphire='\033[38;2;116;199;236m'  # #74c7ec — Sapphire
c_lavender='\033[38;2;180;190;254m'  # #b4befe — Lavender
c_mauve='\033[38;2;203;166;247m'     # #cba6f7 — Mauve
c_gold='\033[38;2;249;226;175m'      # #f9e2af — Yellow
c_green='\033[38;2;166;227;161m'     # #a6e3a1 — Green
c_peach='\033[38;2;250;179;135m'     # #fab387 — Peach
c_red='\033[38;2;243;139;168m'       # #f38ba8 — Red

status_color() {
  local pct=$1
  if [ "$pct" -lt 50 ]; then
    printf '%s' "$c_green"
  elif [ "$pct" -lt 75 ]; then
    printf '%s' "$c_peach"
  else
    printf '%s' "$c_red"
  fi
}

CTX_COLOR=$c_green
[ -n "$used" ] && CTX_COLOR=$(status_color "$used")

# ── OSC 8 clickable links ──
osc_link() {
  printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$1" "$2"
}
osc_url() {
  printf '\033]8;;%s\033\\%s\033]8;;\033\\' "$1" "$2"
}

# Separators
S="${c_sep} │ ${RST}"
DOT="${c_sep} · ${RST}"

# Suppress stderr from output
exec 2>/dev/null

# ═══════════════════════════════════════════════════
# LINE 1 — Path · Branch │ Model [│ VIM] [│ Agent]
# ═══════════════════════════════════════════════════
printf "${c_sapphire}"
osc_link "$dir" "$short_dir"
if [ -n "$git_branch" ]; then
  printf "${RST}${DOT}${c_green}"
  if [ -n "$github_branch_url" ]; then
    osc_url "$github_branch_url" "$git_branch"
  else
    printf "%s" "$git_branch"
  fi
  printf "${RST}"
fi
printf "${RST}${S}${c_lavender}${BOLD}%s${RST}" "$model"
[ -n "$thinking" ] && printf " ${c_mauve}${ITALIC}%s${RST}" "$thinking"
[ -n "$vim_mode" ] && printf "${S}${c_mauve}VIM ${BOLD}%s${RST}" "$vim_mode"
[ -n "$agent_name" ] && printf "${S}${c_lavender}%s${RST}" "$agent_name"
printf '\n'

# ═══════════════════════════════════════════════════
# LINE 2 — Context │ 5h Quota │ $Cost · 7d Quota
# ═══════════════════════════════════════════════════
if [ -n "$used" ]; then
  ctx_warn=""
  if [ "$used" -ge 80 ]; then
    ctx_warn=" 🚨"
  elif [ "$used" -ge 60 ]; then
    ctx_warn=" ⚠️"
  fi
  printf "${c_gold}%s%%${RST}${c_dim}/%s${RST}%s" "$used" "$f_ctx_size" "$ctx_warn"
else
  printf "${c_dim}—${RST}"
fi
printf "${S}"
if [ -n "$five_hr_used" ] && [ -n "$seven_day_used" ]; then
  five_hr_used=${five_hr_used%%.*}
  seven_day_used=${seven_day_used%%.*}
  [ -z "$five_hr_used" ] && five_hr_used=0
  [ -z "$seven_day_used" ] && seven_day_used=0
  five_left=$((100 - five_hr_used))
  seven_left=$((100 - seven_day_used))
  FIVE_C=$(status_color "$five_hr_used")
  SEVEN_C=$(status_color "$seven_day_used")
  f_five_r=$(fmt_reset "$five_hr_reset")
  f_seven_r=$(fmt_reset_days "$seven_day_reset")
  printf "${FIVE_C}${BOLD}"
  osc_url "https://claude.ai/settings/usage" "${five_left}%"
  printf "${RST}"
  [ -n "$f_five_r" ] && printf " ${c_dim}(%s)${RST}" "$f_five_r"
  printf "${DOT}"
  printf "${SEVEN_C}${BOLD}"
  osc_url "https://claude.ai/settings/usage" "${seven_left}%"
  printf "${RST}"
  [ -n "$f_seven_r" ] && printf " ${c_dim}(%s)${RST}" "$f_seven_r"
  printf "${S}"
  printf "${c_gold}${BOLD}%s${RST}" "$f_cost"
else
  printf "${c_label}"
  osc_url "https://claude.ai/settings/usage" "Quota —"
  printf "${RST}"
  printf "${S}${c_gold}${BOLD}%s${RST}" "$f_cost"
fi
printf '\n'
