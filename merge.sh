#!/usr/bin/env bash
# Merger for the worktrunk herdr plugin — merge the currently open worktree into
# a target selected with fzf, then remove the source worktree. Plain bash,
# shell-agnostic: it calls the `wt` binary directly, so it needs no
# shell-function/rc integration.

if ! command -v fzf >/dev/null; then
  printf '\033[31m%s\033[0m\n' "fzf not found on PATH"; sleep 2; exit 1
fi

action_flags=()
case ${1:-} in
  "")
    ;;
  --no-squash)
    action_flags=(--no-squash)
    ;;
  *)
    printf '\033[31m%s\033[0m\n' "unsupported merger option: $1" >&2
    exit 2
    ;;
esac

plugin_root=${HERDR_PLUGIN_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
# shellcheck source=./config.sh
source "$plugin_root/config.sh"
# shellcheck source=./helpers.sh
source "$plugin_root/helpers.sh"
# shellcheck source=./lifecycle.sh
source "$plugin_root/lifecycle.sh"

# Configured flags first, then the ones this action adds, skipping any the config
# already asked for so `wt merge` never sees the same flag twice.
merge_flags=()
while IFS= read -r flag; do
  merge_flags+=("$flag")
done < <(worktrunk_merge_flags)
for flag in "${action_flags[@]}"; do
  if [[ " ${merge_flags[*]} " != *" $flag "* ]]; then
    merge_flags+=("$flag")
  fi
done

worktrunk_fzf_layout

wtitems=$(worktrunk_worktree_items) || exit 1

source_branch=$(git branch --show-current)
if [[ -z $source_branch ]]; then
  printf '\033[31m%s\033[0m\n' "cannot merge a detached worktree"; sleep 2; exit 1
fi

# Resolve the source while it still exists: after a successful merge the target
# context removes it, then its native workspace (if any) can be closed.
source_path=$(printf '%s\n' "$wtitems" | worktrunk_worktree_path "$source_branch")
if [[ -z $source_path ]]; then
  printf '\033[31m%s\033[0m\n' "current branch has no worktree: $source_branch"; sleep 2; exit 1
fi

source_is_main=$(printf '%s\n' "$wtitems" \
  | jq -r --arg branch "$source_branch" \
      'select(.kind == "worktree" and .branch == $branch) | .is_main')
if [[ $source_is_main == true ]]; then
  printf '\033[33m%s\033[0m\n' "cannot merge the primary worktree into another branch"; sleep 2; exit 1
fi

cands=$(printf '%s\n' "$wtitems" | worktrunk_merge_target_branches "$source_branch")
if [[ -z $cands ]]; then
  printf '\033[33m%s\033[0m\n' "No merge target worktrees (only the current worktree exists)."; sleep 2; exit 0
fi

# Spell out the exact wt invocation in the header: which flags are in play is the
# difference between this action and its no-squash variant, and between one user's
# merge_flags and another's.
target_branch=$(printf '%s\n' "$cands" \
  | worktrunk_pick_branch "merge $source_branch into ❯ " \
      "↵ to merge $source_branch into the selected branch${merge_flags[*]:+ ${merge_flags[*]}} · esc to cancel")
[[ -z $target_branch ]] && exit 0      # esc / no selection → cancel

# Enter the target before removing the source so this action never leaves its
# shell process in a deleted working directory.
target_path=$(printf '%s\n' "$wtitems" | worktrunk_worktree_path "$target_branch")
if [[ -z $target_path ]]; then
  printf '\033[31m%s\033[0m\n' "selected target has no worktree: $target_branch"; sleep 2; exit 1
fi
wsid=$(worktrunk_open_workspace_id "$source_path")

# --no-remove because wt merge's own removal runs in the background, which would
# race the workspace close below; the foreground `wt remove` further down does it.
# wt merge stages, commits, squashes and rebases per its flags, runs pre-commit and
# pre-merge hooks, and stops on conflicts — so run it interactively and let
# worktrunk gate all of that.
if ! wt merge --no-remove "$target_branch" "${merge_flags[@]}"; then
  printf '\n\033[31m%s\033[0m press any key to close' "wt merge failed (see above)."; read -n1
  exit 0
fi

# The branch is merged now, so wt remove deletes it without -D. --foreground blocks
# until the worktree is really gone, so closing its workspace can't outrun it.
if ! cd "$target_path" || ! wt remove --foreground "$source_branch"; then
  printf '\n\033[31m%s\033[0m press any key to close' \
    "merged, but wt remove failed (see above)."; read -n1
  exit 0
fi

worktrunk_close_worktree_ui "$wsid" "$source_path"
