#!/usr/bin/env bash
# Tests for the clickline.conf parser (_load_conf in statusline.sh).
#
# clickline.conf is parsed, not sourced, so config values are literal text.
# These tests pin the parsing rules that users can actually trip over:
# inline comments, quoting, and the interaction between the two.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/clickline-conf-test.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.claude"

# Keep the render offline and deterministic.
FAKEBIN="$TMPDIR/bin"
mkdir -p "$FAKEBIN"
for _fake in security curl gh; do
  printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/$_fake"
  chmod +x "$FAKEBIN/$_fake"
done
export PATH="$FAKEBIN:$PATH"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\nExpected output to contain: %s\nGot: %s\n' "$label" "$needle" "$haystack" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL: %s\nExpected output not to contain: %s\nGot: %s\n' "$label" "$needle" "$haystack" >&2
    return 1
  fi
}

write_conf() {
  printf '%s\n' "$@" > "$HOME/.claude/clickline.conf"
}

statusline_json() {
  local dir="$1"
  jq -n --arg dir "$dir" '{
    model: {display_name: "Test Model", id: "test"},
    workspace: {current_dir: $dir},
    context_window: {used_percentage: 1, context_window_size: 200000},
    cost: {total_cost_usd: 0, total_duration_ms: 1000},
    version: "test"
  }'
}

# stdout only — parser warnings go to stderr and must never reach the statusline.
run_statusline() {
  local dir="$1"
  bash "$ROOT/statusline.sh" <<<"$(statusline_json "$dir")" 2>/dev/null
}

run_statusline_stderr() {
  local dir="$1"
  bash "$ROOT/statusline.sh" <<<"$(statusline_json "$dir")" 2>&1 >/dev/null
}

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test User"
printf 'hello\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial
branch=$(git -C "$repo" branch --show-current)

base_conf=(SHOW_QUOTA=false SHOW_PR=false SHOW_CI=false SHOW_COMMIT=false SHOW_DIRTY=false)

# ── Quoted value containing " #" ──────────────────────────────────────────────
# Regression test: comment stripping must run AFTER quote handling. Stripping
# first truncated the value and left an orphaned leading quote, which poisoned
# the first LAYOUT token so `path` silently stopped rendering.
write_conf "LAYOUT='path branch # foo'" "${base_conf[@]}"
output=$(run_statusline "$repo")
assert_contains "$output" "repo" "single-quoted LAYOUT with ' #' still renders path"
assert_contains "$output" "$branch" "single-quoted LAYOUT with ' #' still renders branch"
assert_not_contains "$output" "'path" "single-quoted LAYOUT leaves no orphaned quote"
printf 'ok - single-quoted LAYOUT containing " #"\n'

write_conf 'LAYOUT="path branch # foo"' "${base_conf[@]}"
output=$(run_statusline "$repo")
assert_contains "$output" "repo" "double-quoted LAYOUT with ' #' still renders path"
assert_contains "$output" "$branch" "double-quoted LAYOUT with ' #' still renders branch"
printf 'ok - double-quoted LAYOUT containing " #"\n'

# ── Inline comments on unquoted values ────────────────────────────────────────
write_conf "LAYOUT='path branch'   # trailing comment" \
  "SHOW_BRANCH=true    # inline comment" "${base_conf[@]}"
output=$(run_statusline "$repo")
assert_contains "$output" "$branch" "inline comment after bool is stripped"
printf 'ok - inline comments stripped from unquoted values\n'

# A comment marker with no preceding whitespace is part of the value.
write_conf "LAYOUT='path branch'" "BRANCH_MAX_CHARS=25#notacomment" "${base_conf[@]}"
output=$(run_statusline "$repo")
assert_contains "$output" "$branch" "value with bare # does not break rendering"
printf 'ok - "#" without preceding whitespace is not a comment\n'

# ── Whole-line comments ───────────────────────────────────────────────────────
write_conf "# LAYOUT='path'" "   # indented comment" "LAYOUT='path branch'" "${base_conf[@]}"
output=$(run_statusline "$repo")
assert_contains "$output" "$branch" "commented-out keys are ignored"
printf 'ok - whole-line comments ignored\n'

# ── Values are literal, not expanded ──────────────────────────────────────────
# `source` used to expand these; the parser stores them verbatim. A literal
# "$(...)" in THEME must never be executed.
marker="$TMPDIR/command-substitution-ran"
rm -f "$marker"
write_conf "LAYOUT='path branch'" "THEME=\$(touch '$marker')" "${base_conf[@]}"
run_statusline "$repo" >/dev/null
if [ -e "$marker" ]; then
  printf 'FAIL: command substitution in a config value was executed\n' >&2
  exit 1
fi
printf 'ok - config values are literal (no command substitution)\n'

# ── Unrecognized keys warn on stderr and never reach stdout ───────────────────
write_conf "LAYOUT='path branch'" "TOTALLY_UNKNOWN_KEY=value" "${base_conf[@]}"
errout=$(run_statusline_stderr "$repo")
assert_contains "$errout" "TOTALLY_UNKNOWN_KEY" "unrecognized key reported on stderr"
output=$(run_statusline "$repo")
assert_not_contains "$output" "TOTALLY_UNKNOWN_KEY" "warning does not leak into statusline stdout"
printf 'ok - unrecognized config keys warn on stderr\n'

# Recognized keys must stay silent.
write_conf "LAYOUT='path branch'" "${base_conf[@]}"
errout=$(run_statusline_stderr "$repo")
assert_not_contains "$errout" "unrecognized config key" "known keys produce no warning"
printf 'ok - recognized config keys produce no warning\n'
