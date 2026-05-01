#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/clickline-git-test.XXXXXX")
trap 'rm -rf "$TMPDIR"' EXIT

export HOME="$TMPDIR/home"
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/clickline.conf" <<'CONF'
LAYOUT='path branch'
SHOW_QUOTA=false
SHOW_PR=false
SHOW_CI=false
SHOW_COMMIT=false
SHOW_DIRTY=false
CONF

FAKEBIN="$TMPDIR/bin"
mkdir -p "$FAKEBIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/security"
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKEBIN/curl"
chmod +x "$FAKEBIN/security" "$FAKEBIN/curl"
export PATH="$FAKEBIN:$PATH"

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'FAIL: %s\nExpected output to contain: %s\n' "$label" "$needle" >&2
    return 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'FAIL: %s\nExpected output not to contain: %s\n' "$label" "$needle" >&2
    return 1
  fi
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

run_statusline() {
  local dir="$1"
  bash "$ROOT/statusline.sh" <<<"$(statusline_json "$dir")"
}

repo="$TMPDIR/repo"
mkdir -p "$repo"
git -C "$repo" init -q
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name "Test User"
printf 'hello\n' > "$repo/file.txt"
git -C "$repo" add file.txt
git -C "$repo" commit -qm initial
git -C "$repo" remote add origin git@github.com:example/project.git

default_branch=$(git -C "$repo" branch --show-current)
git -C "$repo" update-ref "refs/remotes/origin/$default_branch" HEAD
git -C "$repo" branch --set-upstream-to="origin/$default_branch" "$default_branch" >/dev/null
output=$(run_statusline "$repo")
assert_contains "$output" "$default_branch" "normal repository branch"
assert_contains "$output" "https://github.com/example/project/tree/$default_branch" "normal repository GitHub link"
printf 'ok - normal repository branch\n'

linked="$TMPDIR/linked"
git -C "$repo" worktree add -q -b feature/linked "$linked"
git -C "$linked" update-ref refs/remotes/origin/feature/linked HEAD
git -C "$linked" branch --set-upstream-to=origin/feature/linked feature/linked >/dev/null
output=$(run_statusline "$linked")
assert_contains "$output" "feature/linked" "linked worktree branch"
assert_contains "$output" "https://github.com/example/project/tree/feature/linked" "linked worktree GitHub link"
printf 'ok - linked worktree branch\n'

renamed="$TMPDIR/renamed"
git -C "$repo" worktree add -q -b local-name "$renamed"
git -C "$renamed" update-ref refs/remotes/origin/remote-name HEAD
git -C "$renamed" branch --set-upstream-to=origin/remote-name local-name >/dev/null
output=$(run_statusline "$renamed")
assert_contains "$output" "local-name" "local branch with differently named upstream"
assert_contains "$output" "https://github.com/example/project/tree/remote-name" "differently named upstream GitHub link"
assert_not_contains "$output" "https://github.com/example/project/tree/local-name" "local branch name GitHub link"
printf 'ok - differently named upstream branch\n'

nested="$linked/nested/path"
mkdir -p "$nested"
output=$(run_statusline "$nested")
assert_contains "$output" "feature/linked" "nested linked worktree branch"
assert_contains "$output" "https://github.com/example/project/tree/feature/linked" "nested linked worktree GitHub link"
printf 'ok - nested linked worktree directory\n'

local_only="$TMPDIR/local-only"
git -C "$repo" worktree add -q -b feature/local-only "$local_only"
output=$(run_statusline "$local_only")
assert_contains "$output" "feature/local-only" "local-only worktree branch"
assert_not_contains "$output" "https://github.com/example/project/tree/feature/local-only" "local-only branch GitHub link"
printf 'ok - local-only worktree branch\n'

git -C "$linked" remote add internal ssh://git@example.com/project.git
git -C "$linked" update-ref refs/remotes/internal/feature/linked HEAD
git -C "$linked" branch --set-upstream-to=internal/feature/linked feature/linked >/dev/null
output=$(run_statusline "$linked")
assert_contains "$output" "feature/linked" "non-GitHub upstream branch"
assert_not_contains "$output" "ssh://git@example.com/project.git/tree/feature/linked" "non-GitHub upstream link"
assert_not_contains "$output" "https://github.com/example/project/tree/feature/linked" "stale GitHub origin link for non-GitHub upstream"
printf 'ok - non-GitHub upstream\n'

sha=$(git -C "$repo" rev-parse --short HEAD)
git -C "$repo" checkout -q --detach HEAD
output=$(run_statusline "$repo")
assert_contains "$output" "detached@$sha" "detached HEAD label"
assert_contains "$output" "https://github.com/example/project/tree/$sha" "detached HEAD GitHub link"
printf 'ok - detached HEAD\n'

nonrepo="$TMPDIR/nonrepo"
mkdir -p "$nonrepo"
output=$(run_statusline "$nonrepo")
assert_not_contains "$output" "detached@" "non-git detached label"
assert_not_contains "$output" "github.com/example/project" "non-git GitHub link"
printf 'ok - non-git directory\n'
