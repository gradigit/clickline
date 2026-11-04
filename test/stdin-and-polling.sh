#!/usr/bin/env bash
# Tests for statusline input fields (rate_limits, prompt_cache, pr) and for
# the background lookups never retrying on every render.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/clickline-stdin-test.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
export CLICKLINE_TMP_DIR="$TMPDIR/cache"   # keep the real /tmp caches untouched
mkdir -p "$HOME/.claude" "$CLICKLINE_TMP_DIR"
export GIT_CONFIG_GLOBAL="$TMPDIR/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.name test
git config --global user.email test@example.com
git config --global init.defaultBranch main

# Fake curl / gh / security that log each call and fail
FAKEBIN="$TMPDIR/bin"
CALLS="$TMPDIR/calls"
mkdir -p "$FAKEBIN"
for tool in curl gh security; do
  printf '#!/usr/bin/env bash\necho %s >> "%s"\nexit 1\n' "$tool" "$CALLS" > "$FAKEBIN/$tool"
  chmod +x "$FAKEBIN/$tool"
done
export PATH="$FAKEBIN:$PATH"
: > "$CALLS"
calls() { grep -c "^$1\$" "$CALLS" || true; }

fails=0
check() {  # check <label> <haystack> <needle> [present|absent]
  local label="$1" haystack="$2" needle="$3" mode="${4:-present}"
  if { [ "$mode" = present ] && [[ "$haystack" == *"$needle"* ]]; } \
     || { [ "$mode" = absent ] && [[ "$haystack" != *"$needle"* ]]; }; then
    printf 'ok - %s\n' "$label"
  else
    printf 'FAIL: %s\nExpected %s: %s\nGot: %s\n' "$label" "$mode" "$needle" "$haystack" >&2
    fails=$(( fails + 1 ))
  fi
}
check_eq() {  # check_eq <label> <actual> <expected>
  if [ "$2" = "$3" ]; then printf 'ok - %s\n' "$1"
  else printf 'FAIL: %s\nExpected: %s\nGot: %s\n' "$1" "$3" "$2" >&2; fails=$(( fails + 1 )); fi
}

conf() { printf '%s\n' "$@" > "$HOME/.claude/clickline.conf"; }

NOW=$(date +%s)
T() { echo $(( $(date +%s) + $1 )); }   # fresh timestamp: time checks keep a margin
# render <dir> <extra jq object merged into the input>
render() {
  local dir="$1" extra="${2:-{\}}"
  jq -n --arg dir "$dir" --argjson extra "$extra" '{
    model: {display_name: "Test Model", id: "test"},
    workspace: {current_dir: $dir},
    context_window: {used_percentage: 1, context_window_size: 200000},
    cost: {total_cost_usd: 0, total_duration_ms: 1000},
    version: "test"
  } * $extra' | bash "$ROOT/statusline.sh" | sed 's/\x1b\[[0-9;]*m//g'
}
links() { grep -o $'\e]8;;[^\e]*' <<<"$1" | sed 's/^.\]8;;//' | grep -v '^$' || true; }
wait_for() {  # wait_for <file> <grep pattern>: background lookups finish asynchronously
  local i; for i in $(seq 50); do grep -q -- "$2" "$1" 2>/dev/null && return 0; sleep 0.1; done; return 1
}

PLAIN="$TMPDIR/plain"; mkdir -p "$PLAIN"

# ── Quota from rate_limits ───────────────────────────────────────────────────
conf "LAYOUT='quota'" "SHOW_PR=false"
out=$(render "$PLAIN" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":42.7,\"resets_at\":$((NOW+200000))}}}")
check "weekly-only quota renders (no five_hour)" "$out" "58%"
check "weekly-only quota is not blank" "$out" "Quota —" absent
check "weekly-only quota shows day reset" "$out" "(2d7h)"

out=$(render "$PLAIN" "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":37,\"resets_at\":$(T 7530)},\"seven_day\":{\"used_percentage\":42,\"resets_at\":$((NOW+200000))}}}")
check "both windows render" "$out" "63%"
check "both windows: 5h reset" "$out" "(2h5m)"

rm -f "$CLICKLINE_TMP_DIR"/.clickline-quota-*   # no newer window known from other sessions
out=$(render "$PLAIN" "{\"rate_limits\":{\"five_hour\":{\"used_percentage\":91,\"resets_at\":$((NOW-60))}}}")
check "window past its reset shows 100%" "$out" "100%"
check "window past its reset shows no countdown" "$out" "(" absent
check_eq "stdin quota makes no API call" "$(calls curl)" "0"

# ── Quota shared across sessions ─────────────────────────────────────────────
W1=$((NOW+300000)); W2=$((NOW+900000))
render "$PLAIN" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":$W1}}}" >/dev/null
out=$(render "$PLAIN" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":30,\"resets_at\":$W1}}}")
check "idle session shows the highest usage seen in the window" "$out" "50%"
render "$PLAIN" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":5,\"resets_at\":$W2}}}" >/dev/null
out=$(render "$PLAIN" "{\"rate_limits\":{\"seven_day\":{\"used_percentage\":50,\"resets_at\":$W1}}}")
check "session from an older window shows the newer window" "$out" "95%"

# ── Quota fallback (no rate_limits): throttled, backs off ────────────────────
rm -f "$CLICKLINE_TMP_DIR"/.clickline-quota-*
printf '{"claudeAiOauth":{"accessToken":"t"}}' > "$HOME/.claude/.credentials.json"
: > "$CALLS"
out=$(render "$PLAIN")
check "fallback failure shows Quota —" "$out" "Quota —"
for _ in 1 2 3 4 5; do render "$PLAIN" >/dev/null; done
check_eq "failing usage API called once across 6 renders" "$(calls curl)" "1"
check_eq "failure recorded for backoff" "$(cut -d' ' -f2 "$CLICKLINE_TMP_DIR/.claude-usage-attempt")" "1"

printf '%s {"five_hour":null,"seven_day":{"utilization":43.0,"resets_at":"2030-01-01T00:00:00+00:00"}}\n' "$((NOW-5))" > "$CLICKLINE_TMP_DIR/.claude-usage-cache"
out=$(render "$PLAIN")
check "cached API response with five_hour:null renders" "$out" "57%"
printf '%s {"five_hour":null,"seven_day":{"utilization":43.0,"resets_at":"2030-01-01T00:00:00+00:00"}}\n' "$((NOW-100000))" > "$CLICKLINE_TMP_DIR/.claude-usage-cache"
out=$(render "$PLAIN")
check "very old cached response is not shown" "$out" "Quota —"

# ── Prompt cache ─────────────────────────────────────────────────────────────
conf "LAYOUT='cache'"
out=$(render "$PLAIN" "{\"prompt_cache\":{\"warm\":true,\"ttl\":\"1h\",\"expires_at\":$(T 3270),\"hit_ratio\":0.973}}")
check "warm cache shows minutes left" "$out" "cache 54m"
check "warm cache shows hit rate" "$out" "97% hit"
out=$(render "$PLAIN" "{\"prompt_cache\":{\"warm\":true,\"ttl\":\"5m\",\"expires_at\":$(T 40),\"hit_ratio\":0.5}}")
check "nearly expired cache shows seconds" "$out" "s 50% hit"
check "nearly expired cache is not shown in minutes" "$out" "m 50% hit" absent
out=$(render "$PLAIN" "{\"prompt_cache\":{\"warm\":false,\"ttl\":\"1h\",\"expires_at\":$((NOW-10)),\"hit_ratio\":0.9}}")
check "expired cache shows cold" "$out" "cache cold"
out=$(render "$PLAIN")
check "no prompt_cache shows nothing" "$out" "cache" absent

# ── PR ───────────────────────────────────────────────────────────────────────
REPO="$TMPDIR/repo"
git init -q "$REPO"
git -C "$REPO" commit -q --allow-empty -m init
git -C "$REPO" remote add origin https://someone@github.com/example/project.git
git -C "$REPO" switch -q -c feature/x

conf "LAYOUT='pr'" "SHOW_PR=true" "SHOW_QUOTA=false"
: > "$CALLS"
out=$(render "$REPO" '{"pr":{"number":42,"url":"https://github.com/example/project/pull/42"}}')
check "PR from stdin renders" "$out" "#42"
check "PR from stdin links to the PR" "$(links "$out")" "https://github.com/example/project/pull/42"
check_eq "PR from stdin makes no gh call" "$(calls gh)" "0"

PR_CACHE=$(ls "$CLICKLINE_TMP_DIR"/.clickline-pr-* 2>/dev/null || true)
check_eq "no PR cache written when Claude Code supplies the PR" "$PR_CACHE" ""
out=$(render "$REPO")
check "no 'New PR' before the lookup confirms there's no PR" "$out" "New PR" absent
PR_CACHE=$(ls "$CLICKLINE_TMP_DIR"/.clickline-pr-*)
wait_for "$PR_CACHE" ' {}$' || true
for _ in 1 2 3 4 5; do render "$REPO" >/dev/null; done
check_eq "branch without a PR: gh called once across 6 renders" "$(calls gh)" "1"
out=$(render "$REPO")
check "'New PR' once the lookup found no PR" "$out" "New PR"
check "user@github.com remote → compare link" "$(links "$out")" "https://github.com/example/project/compare/feature/x?expand=1"

# ── Dirty count: staged + modified file counts once ──────────────────────────
conf "LAYOUT='branch'" "SHOW_DIRTY=true" "SHOW_PR=false" "SHOW_QUOTA=false"
echo a > "$REPO/f"; git -C "$REPO" add f; echo b > "$REPO/f"
out=$(render "$REPO")
check "file both staged and modified counts once" "$out" "feature/x·1"

# ── Custom items: repo .clickline is static ──────────────────────────────────
MARKER="$TMPDIR/repo-cmd-ran"
jq -n --arg m "$MARKER" '{evil: {label: "repo-label", cmd: ("touch " + $m), condition: ("touch " + $m)}}' > "$REPO/.clickline"
printf '{"clock":{"label":"x","cmd":"echo global-cmd-output"}}' > "$HOME/.claude/clickline-custom.json"
conf "LAYOUT='custom_evil custom_clock'" "SHOW_PR=false" "SHOW_QUOTA=false"
out=$(render "$REPO")
check "repo item shows its static label" "$out" "repo-label"
check_eq "repo item cmd/condition never run" "$( [ -e "$MARKER" ] && echo ran || echo not-run)" "not-run"
check "global item cmd still runs" "$out" "global-cmd-output"

# ── Cleanup: daily, top level only ───────────────────────────────────────────
mkdir -p "$CLICKLINE_TMP_DIR/sub"
touch -t 202001010000 "$CLICKLINE_TMP_DIR/.clickline-old" "$CLICKLINE_TMP_DIR/sub/.clickline-nested"
rm -f "$CLICKLINE_TMP_DIR/.clickline-cleanup-stamp"
render "$PLAIN" >/dev/null
for _ in $(seq 50); do [ -e "$CLICKLINE_TMP_DIR/.clickline-old" ] || break; sleep 0.1; done
check_eq "old top-level cache file removed" "$( [ -e "$CLICKLINE_TMP_DIR/.clickline-old" ] && echo kept || echo removed)" "removed"
check_eq "nested files left alone" "$( [ -e "$CLICKLINE_TMP_DIR/sub/.clickline-nested" ] && echo kept || echo removed)" "kept"
touch -t 202001010000 "$CLICKLINE_TMP_DIR/.clickline-old2"
render "$PLAIN" >/dev/null; sleep 0.3
check_eq "cleanup runs at most once a day" "$( [ -e "$CLICKLINE_TMP_DIR/.clickline-old2" ] && echo kept || echo removed)" "kept"

if [ "$fails" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$fails" >&2
  exit 1
fi
printf '\nall checks passed\n'
