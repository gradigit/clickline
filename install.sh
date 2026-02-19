#!/bin/bash
# clickline installer + settings manager
# https://github.com/gradigit/clickline
#
# Usage:
#   bash install.sh           — install or reconfigure
#   bash install.sh --quota   — troubleshoot quota display
#   curl -fsSL https://raw.githubusercontent.com/gradigit/clickline/main/install.sh | bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd 2>/dev/null || true)"
CONF="$HOME/.claude/clickline.conf"
STATUSLINE="$HOME/.claude/statusline.sh"
SETTINGS="$HOME/.claude/settings.json"

# ── Colors ───────────────────────────────────────────────────────────────────
_green()  { printf '\033[38;2;166;227;161m%s\033[0m' "$1"; }
_peach()  { printf '\033[38;2;250;179;135m%s\033[0m' "$1"; }
_red()    { printf '\033[38;2;243;139;168m%s\033[0m' "$1"; }
_dim()    { printf '\033[38;2;69;71;90m%s\033[0m' "$1"; }
_bold()   { printf '\033[1m%s\033[0m' "$1"; }
_ok()     { printf '  %s %s\n' "$(_green '✓')" "$1"; }
_warn()   { printf '  %s %s\n' "$(_peach '!')" "$1"; }
_fail()   { printf '  %s %s\n' "$(_red '✗')" "$1"; }

# ── Dependency check ─────────────────────────────────────────────────────────
check_deps() {
  printf '\n%s\n' "$(_bold 'Checking dependencies...')"
  local ok=true

  for dep in jq git curl; do
    if command -v "$dep" >/dev/null 2>&1; then
      _ok "$dep $(_dim '(required)')"
    else
      _fail "$dep $(_dim '(required — please install)')"
      ok=false
    fi
  done

  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      _ok "gh $(_dim '(optional — PR and CI features enabled)')"
    else
      _warn "gh $(_dim '(found but not authenticated — run: gh auth login)')"
    fi
  else
    _warn "gh $(_dim '(optional — needed for PR and CI features)')"
  fi

  if command -v fzf >/dev/null 2>&1; then
    _ok "fzf $(_dim '(optional — interactive selector)')"
  else
    _warn "fzf $(_dim '(optional — using numbered menu instead)')"
  fi

  [ "$ok" = "false" ] && { printf '\nInstall missing required dependencies and re-run.\n'; exit 1; }
}

# ── Quota troubleshooter ─────────────────────────────────────────────────────
troubleshoot_quota() {
  printf '\n%s\n\n' "$(_bold 'Checking quota setup...')"

  _step() { printf 'Step %d: %-38s' "$1" "$2"; }

  _step 1 'jq installed'
  if command -v jq >/dev/null 2>&1; then printf '%s\n' "$(_green '✓')"; else printf '%s\n' "$(_red '✗')"; _fail 'Install jq: brew install jq'; return 1; fi

  _step 2 'curl installed'
  if command -v curl >/dev/null 2>&1; then printf '%s\n' "$(_green '✓')"; else printf '%s\n' "$(_red '✗')"; _fail 'Install curl: brew install curl'; return 1; fi

  _step 3 'Claude Code keychain entry'
  local raw
  raw=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null || true)
  if [ -n "$raw" ]; then printf '%s\n' "$(_green '✓')"; else
    printf '%s\n' "$(_red '✗')"
    _fail 'Keychain entry missing. Sign in to Claude Code first.'
    return 1
  fi

  _step 4 'OAuth token extractable'
  local token
  token=$(echo "$raw" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null || true)
  if [ -n "$token" ]; then printf '%s\n' "$(_green '✓')"; else
    printf '%s\n' "$(_red '✗')"
    _fail 'Could not parse token from keychain entry.'
    _fail 'Fix: run /logout then /login in Claude Code'
    return 1
  fi

  _step 5 'API call succeeds'
  local resp
  resp=$(curl -s --max-time 5 \
    -H "Authorization: Bearer $token" \
    -H "anthropic-beta: oauth-2025-04-20" \
    "https://api.anthropic.com/api/oauth/usage" 2>/dev/null || true)

  if [ -z "$resp" ]; then
    printf '%s\n' "$(_red '✗')"
    _fail 'No response from API (network issue or timeout)'
    return 1
  fi

  local err_type err_msg
  err_type=$(echo "$resp" | jq -r '.error.type // empty' 2>/dev/null || true)
  err_msg=$(echo "$resp"  | jq -r '.error.message // empty' 2>/dev/null || true)

  if [ -n "$err_type" ]; then
    printf '%s\n' "$(_red '✗')"
    _fail "Error: $err_type — $err_msg"
    case "$err_type" in
      permission_error)
        _fail 'Fix: run /logout then /login in Claude Code to refresh token scopes' ;;
      authentication_error)
        _fail 'Fix: run /logout then /login in Claude Code' ;;
      *)
        _fail "Unexpected error. Check https://status.anthropic.com" ;;
    esac
    return 1
  fi

  if echo "$resp" | jq -e '.five_hour' >/dev/null 2>&1; then
    printf '%s\n' "$(_green '✓')"
  else
    printf '%s\n' "$(_red '✗')"
    _fail "Unexpected response shape. Raw: $(echo "$resp" | head -c 200)"
    return 1
  fi

  _step 6 'Usage data parseable'
  local util
  util=$(echo "$resp" | jq -r '.five_hour.utilization // empty' 2>/dev/null || true)
  if [ -n "$util" ]; then
    printf '%s\n' "$(_green '✓')"
    printf '\n%s\n' "$(_green 'Quota is working correctly!')"
    printf '5h utilization: %s%%\n' "$(echo "$util" | awk '{printf "%d", $1*100}')"
  else
    printf '%s\n' "$(_red '✗')"
    _fail 'five_hour.utilization missing from response'
  fi
}

# ── Load existing config (or defaults) ───────────────────────────────────────
load_conf() {
  SHOW_BRANCH=${SHOW_BRANCH:-true}
  SHOW_DIRTY=${SHOW_DIRTY:-true}
  SHOW_AHEAD_BEHIND=${SHOW_AHEAD_BEHIND:-false}
  SHOW_COMMIT=${SHOW_COMMIT:-false}
  SHOW_PR=${SHOW_PR:-true}
  SHOW_CI=${SHOW_CI:-false}
  SHOW_MODEL=${SHOW_MODEL:-true}
  SHOW_VERSION=${SHOW_VERSION:-false}
  SHOW_CONTEXT=${SHOW_CONTEXT:-true}
  SHOW_QUOTA=${SHOW_QUOTA:-true}
  SHOW_COST=${SHOW_COST:-true}
  BRANCH_MAX_CHARS=${BRANCH_MAX_CHARS:-25}
  PATH_SEGMENTS=${PATH_SEGMENTS:-2}
  PATH_LINK_TARGET=${PATH_LINK_TARGET:-finder}
  PR_CACHE_TTL=${PR_CACHE_TTL:-60}
  CI_CACHE_TTL=${CI_CACHE_TTL:-30}
  QUOTA_CACHE_TTL=${QUOTA_CACHE_TTL:-60}
}

# shellcheck source=/dev/null
[ -f "$CONF" ] && source "$CONF" 2>/dev/null
load_conf

# ── fzf version check (requires >= 0.40.0 for load binding) ──────────────────
fzf_ok=false
if command -v fzf >/dev/null 2>&1; then
  fzf_ver=$(fzf --version 2>/dev/null | awk '{print $1}')
  if [ -n "$fzf_ver" ]; then
    if [ "$(printf '%s\n0.40.0\n' "$fzf_ver" | sort -V | head -1)" = "0.40.0" ]; then
      fzf_ok=true
    fi
  fi
fi

# ── Feature selector ─────────────────────────────────────────────────────────
select_features() {
  printf '\n%s\n' "$(_bold 'Select statusline elements:')"

  # Item format: VAR_NAME<tab>Label  ($'...' gives real tab)
  local -a items=(
    $'SHOW_BRANCH\tBranch → GitHub'
    $'SHOW_DIRTY\tDirty indicator (·N modified files)'
    $'SHOW_AHEAD_BEHIND\tAhead/Behind (↑N ↓N commits)'
    $'SHOW_COMMIT\tCommit hash → GitHub commit'
    $'SHOW_PR\tPR link (#N or New PR) — requires gh'
    $'SHOW_CI\tCI status (✓ ✗ ⋯) — requires gh'
    $'SHOW_MODEL\tModel name → Anthropic docs'
    $'SHOW_VERSION\tClaude Code version → GitHub releases'
    $'SHOW_CONTEXT\tContext window percentage'
    $'SHOW_QUOTA\tQuota (5h + 7d usage)'
    $'SHOW_COST\tSession cost → transcript'
  )

  if [ "$fzf_ok" = "true" ]; then
    # Build pre-select actions for currently-enabled items
    local preselect=""
    local idx=1
    for item in "${items[@]}"; do
      varname=$(printf '%s' "$item" | cut -f1)
      val=$(eval "echo \"\${$varname}\"")
      if [ "$val" = "true" ]; then
        preselect="${preselect}${preselect:++}pos($idx)+select"
      fi
      (( idx++ ))
    done

    local bind_str="load:${preselect:-deselect-all}"

    local selected
    selected=$(printf '%s\n' "${items[@]}" | \
      fzf --multi --ansi \
        --header=$'Space to toggle, Enter to confirm\nCurrently selected = enabled' \
        --bind "$bind_str" \
        --with-nth 2.. \
        --delimiter $'\t' \
        --height 40% --border 2>/dev/tty) || true

    # Reset all to false, then enable selected
    for item in "${items[@]}"; do
      varname=$(printf '%s' "$item" | cut -f1)
      eval "$varname=false"
    done
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      varname=$(printf '%s' "$line" | cut -f1)
      eval "$varname=true"
    done <<< "$selected"
  else
    # Numbered fallback
    printf '\n%s\n\n' "$(_dim 'Space-separated numbers to toggle, Enter to keep:')"
    local idx=1
    for item in "${items[@]}"; do
      varname=$(printf '%s' "$item" | cut -f1)
      label=$(printf '%s' "$item" | cut -f2)
      val=$(eval "echo \"\${$varname}\"")
      local mark; [ "$val" = "true" ] && mark="$(_green '[x]')" || mark="$(_dim '[ ]')"
      printf '%s %2d. %s\n' "$mark" "$idx" "$label"
      (( idx++ ))
    done
    printf '\nEnter numbers to toggle (e.g. 3 5 9), or Enter to keep: '
    local input_nums
    read -r input_nums </dev/tty
    if [ -n "$input_nums" ]; then
      for n in $input_nums; do
        if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#items[@]}" ]; then
          local i=$(( n - 1 ))
          varname=$(printf '%s' "${items[$i]}" | cut -f1)
          val=$(eval "echo \"\${$varname}\"")
          [ "$val" = "true" ] && eval "$varname=false" || eval "$varname=true"
        fi
      done
    fi
  fi
}

# ── Path link target ─────────────────────────────────────────────────────────
select_path_target() {
  printf '\n%s\n' "$(_bold 'Cmd+click on directory path opens:')"
  printf '  1. Finder %s\n'    "$( [ "$PATH_LINK_TARGET" = "finder" ] && _dim '(current)' || true)"
  printf '  2. VS Code %s\n'   "$( [ "$PATH_LINK_TARGET" = "vscode" ] && _dim '(current)' || true)"
  printf '  3. Cursor %s\n'    "$( [ "$PATH_LINK_TARGET" = "cursor" ] && _dim '(current)' || true)"
  printf '  4. Nothing %s\n'   "$( [ "$PATH_LINK_TARGET" = "none"   ] && _dim '(current)' || true)"

  local default_num=1
  case "$PATH_LINK_TARGET" in
    finder) default_num=1 ;;
    vscode) default_num=2 ;;
    cursor) default_num=3 ;;
    none)   default_num=4 ;;
  esac

  printf '\nEnter choice [%d]: ' "$default_num"
  local choice
  read -r choice </dev/tty
  choice=${choice:-$default_num}
  case "$choice" in
    1) PATH_LINK_TARGET=finder ;;
    2) PATH_LINK_TARGET=vscode ;;
    3) PATH_LINK_TARGET=cursor ;;
    4) PATH_LINK_TARGET=none ;;
  esac
}

# ── Write config ─────────────────────────────────────────────────────────────
write_conf() {
  mkdir -p "$(dirname "$CONF")"
  cat > "$CONF" << EOF
# clickline config — generated $(date '+%Y-%m-%d')
# Run install.sh again to change settings
# Changes take effect on the next Claude Code response

# ── Features ──────────────────────────────────────────────────────────────────
SHOW_BRANCH=${SHOW_BRANCH}
SHOW_DIRTY=${SHOW_DIRTY}
SHOW_AHEAD_BEHIND=${SHOW_AHEAD_BEHIND}
SHOW_COMMIT=${SHOW_COMMIT}
SHOW_PR=${SHOW_PR}
SHOW_CI=${SHOW_CI}
SHOW_MODEL=${SHOW_MODEL}
SHOW_VERSION=${SHOW_VERSION}
SHOW_CONTEXT=${SHOW_CONTEXT}
SHOW_QUOTA=${SHOW_QUOTA}
SHOW_COST=${SHOW_COST}

# ── Options ───────────────────────────────────────────────────────────────────
BRANCH_MAX_CHARS=${BRANCH_MAX_CHARS}
PATH_SEGMENTS=${PATH_SEGMENTS}
PATH_LINK_TARGET=${PATH_LINK_TARGET}
PR_CACHE_TTL=${PR_CACHE_TTL}
CI_CACHE_TTL=${CI_CACHE_TTL}
QUOTA_CACHE_TTL=${QUOTA_CACHE_TTL}
EOF
  printf '\n%s\n' "$(_green "Config written to $CONF")"
}

# ── Install statusline.sh ─────────────────────────────────────────────────────
install_script() {
  mkdir -p "$(dirname "$STATUSLINE")"
  if [ -f "$SCRIPT_DIR/statusline.sh" ]; then
    cp "$SCRIPT_DIR/statusline.sh" "$STATUSLINE"
  else
    curl -fsSL "https://raw.githubusercontent.com/gradigit/clickline/main/statusline.sh" \
      -o "$STATUSLINE" 2>/dev/null
  fi
  chmod +x "$STATUSLINE"
}

# ── Update ~/.claude/settings.json ───────────────────────────────────────────
update_settings() {
  local cmd="/bin/bash ${STATUSLINE}"
  local tmp
  tmp=$(mktemp)
  if [ -f "$SETTINGS" ]; then
    jq --arg cmd "$cmd" \
      '.statusLine = {"type":"command","command":$cmd,"timeout":5000}' \
      "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"
  else
    printf '{"statusLine":{"type":"command","command":"%s","timeout":5000}}\n' \
      "$cmd" > "$SETTINGS"
  fi
  printf '%s\n' "$(_green "Settings updated: $SETTINGS")"
}

# ── Detect mode ───────────────────────────────────────────────────────────────
if [ "${1:-}" = "--quota" ]; then
  troubleshoot_quota
  exit 0
fi

already_installed=false
if [ -f "$SETTINGS" ] && jq -e '.statusLine.command' "$SETTINGS" 2>/dev/null | grep -q 'statusline.sh'; then
  already_installed=true
fi

printf '\n'
if [ "$already_installed" = "true" ]; then
  printf '%s\n' "$(_bold 'clickline is already installed — reconfiguring')"
else
  printf '%s\n' "$(_bold 'Installing clickline')"
fi

check_deps
select_features
select_path_target
write_conf
install_script
update_settings

printf '\n%s\n' "$(_bold 'Done!')"
if [ "$already_installed" = "true" ]; then
  printf 'Changes take effect on the next Claude Code response.\n\n'
else
  printf 'The statusline will appear at the bottom of your Claude Code terminal.\n'
  printf 'Run %s to reconfigure at any time.\n\n' "$(_dim 'bash install.sh')"
fi
printf 'Tip: %s to troubleshoot quota display.\n\n' "$(_dim 'bash install.sh --quota')"
