#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

stub_dir=$(mktemp -d)
trap 'rm -rf "$stub_dir"' EXIT

config_dir="$stub_dir/config"
mkdir -p "$config_dir"

export WT_STUB_MAIN_PATH="$stub_dir/repo"
export WT_STUB_SOURCE_PATH="$stub_dir/repo.feature"
mkdir -p "$WT_STUB_MAIN_PATH" "$WT_STUB_SOURCE_PATH"

# Stand in for `wt`: list answers with the active feature worktree and its main
# target, and record merge/remove argv for inspection.
cat > "$stub_dir/wt" <<'EOF'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$WT_STUB_LOG"
case "$1" in
  list)
    printf '[{"branch":"main","kind":"worktree","path":"%s","is_main":true},' \
      "$WT_STUB_MAIN_PATH"
    printf '{"branch":"feature","kind":"worktree","path":"%s","is_main":false}]' \
      "$WT_STUB_SOURCE_PATH"
    ;;
  merge)  exit "${WT_STUB_MERGE_STATUS:-0}" ;;
  remove) exit "${WT_STUB_REMOVE_STATUS:-0}" ;;
esac
EOF

# fzf picks the only candidate; the picker's stdin has to be drained either way.
cat > "$stub_dir/fzf" <<'EOF'
#!/usr/bin/env bash
cat > "$FZF_STUB_LOG"
printf '%s\n' "${FZF_STUB_PICK-main}"
EOF

# The merge action must treat the branch in the pane's current worktree as the
# source and offer the other worktree branches as targets.
cat > "$stub_dir/git" <<'EOF'
#!/usr/bin/env bash
if [[ $1 == branch && $2 == --show-current ]]; then
  printf '%s\n' "${GIT_STUB_BRANCH-feature}"
  exit 0
fi
command git "$@"
EOF

cat > "$stub_dir/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "worktree list")
    printf '{"result":{"worktrees":[{"path":"%s","open_workspace_id":"ws-feature"}]}}' \
      "$WT_STUB_SOURCE_PATH"
    ;;
  *) printf '%s\n' "$*" >> "$HERDR_STUB_LOG" ;;
esac
EOF
chmod +x "$stub_dir"/wt "$stub_dir"/fzf "$stub_dir"/git "$stub_dir"/herdr

export PATH="$stub_dir:$PATH"
export WT_STUB_LOG="$stub_dir/wt.log"
export HERDR_STUB_LOG="$stub_dir/herdr.log"
export FZF_STUB_LOG="$stub_dir/fzf.log"

# Run merge.sh with the given argv and the config already in place, then expose
# what wt and herdr were asked to do.
run_merge() {
  : > "$WT_STUB_LOG"
  : > "$HERDR_STUB_LOG"
  : > "$FZF_STUB_LOG"
  HERDR_PLUGIN_ROOT="$repo_root" \
  HERDR_BIN_PATH="$stub_dir/herdr" \
  HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
    bash -c 'cd "$1" && bash "$2" "${@:3}"' -- \
      "$WT_STUB_SOURCE_PATH" "$repo_root/merge.sh" "$@" </dev/null >/dev/null 2>&1
}

assert_log() {
  local label=$1 expected=$2 log=$3
  if ! grep -qxF -- "$expected" "$log"; then
    printf 'expected %s call %q, got:\n%s\n' "$label" "$expected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Matches an action at the beginning of a log entry or after the wt cwd divider,
# so refuting `remove` can't trip over the `--no-remove` merge flag.
refute_log() {
  local label=$1 unexpected=$2 log=$3
  if grep -qE -- "(^|\\|)$unexpected( |$)" "$log"; then
    printf 'unexpected %s call %q in:\n%s\n' "$label" "$unexpected" "$(cat "$log")" >&2
    exit 1
  fi
}

# Default action: merge the current feature worktree into the selected main
# worktree, then remove the source from the target context so the source pane can
# be closed safely.
: > "$config_dir/config.toml"
run_merge
assert_log fzf 'main' "$FZF_STUB_LOG"
assert_log wt "$WT_STUB_SOURCE_PATH|merge --no-remove main" "$WT_STUB_LOG"
assert_log wt "$WT_STUB_MAIN_PATH|remove --foreground feature" "$WT_STUB_LOG"
assert_log herdr 'workspace close ws-feature' "$HERDR_STUB_LOG"

# The no-squash variant adds its flag; config flags come along too, once each.
printf 'merge_flags = "--no-rebase"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt "$WT_STUB_SOURCE_PATH|merge --no-remove main --no-rebase --no-squash" "$WT_STUB_LOG"

printf 'merge_flags = "--no-squash"\n' > "$config_dir/config.toml"
run_merge --no-squash
assert_log wt "$WT_STUB_SOURCE_PATH|merge --no-remove main --no-squash" "$WT_STUB_LOG"

# The primary worktree cannot be removed after a merge, so it is never a valid
# source for this action.
: > "$config_dir/config.toml"
if GIT_STUB_BRANCH=main run_merge; then
  printf 'expected merge.sh to reject the primary worktree as a source\n' >&2
  exit 1
fi
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# An unsupported option is a plugin bug, not a merge to attempt.
: > "$config_dir/config.toml"
if run_merge --no-such-flag; then
  printf 'expected merge.sh to reject an unsupported option\n' >&2
  exit 1
fi
refute_log wt 'merge' "$WT_STUB_LOG"

# Cancelling the picker touches nothing.
FZF_STUB_PICK="" run_merge
refute_log wt 'merge' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A failed merge leaves the worktree and its workspace alone.
WT_STUB_MERGE_STATUS=1 run_merge
refute_log wt 'remove' "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

# A merge that landed but a removal that didn't keeps the workspace open — it still
# holds the worktree.
WT_STUB_REMOVE_STATUS=1 run_merge
assert_log wt "$WT_STUB_MAIN_PATH|remove --foreground feature" "$WT_STUB_LOG"
refute_log herdr 'workspace close' "$HERDR_STUB_LOG"

printf 'merge tests passed\n'
