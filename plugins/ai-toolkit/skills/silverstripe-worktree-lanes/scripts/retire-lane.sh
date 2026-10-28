#!/usr/bin/env bash
# Tear a lane down completely — the GC step. Native worktree cleanup does not know
# about DDEV, so removing the checkout alone leaves an orphaned project with its
# web + db containers and volumes. This deletes the DDEV project first, then the
# worktree and its branch.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: retire-lane.sh <lane> [--root <dir>] [--force]

  <lane>      Short lane id, e.g. "a".
  --root <dir>  Parent dir the worktree lives in (default: alongside repo).
  --force     Skip the uncommitted/unpushed-work guard and force worktree removal.
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
lane="$1"; shift
root=""
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) root="$2"; shift 2 ;;
    --force) force=1;  shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
root="${root:-$(dirname "$repo_root")}"
lane_dir="$root/${repo_name}-wt-${lane}"
lane_branch="wt/${lane}"

[[ -d "$lane_dir" ]] || { echo "error: no lane at $lane_dir." >&2; exit 1; }

# `ddev delete -Oy` run from inside the lane resolves the project via its own
# config (config.local.yaml in local mode), so no edit is needed. Read the pinned
# name only so this message names the right project in both modes.
project="$(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$lane_dir/.ddev/config.local.yaml" 2>/dev/null | head -1)"
project="${project:-${repo_name}-wt-${lane}}"

if [[ "$force" -ne 1 ]]; then
  if [[ -n "$(git -C "$lane_dir" status --porcelain)" ]]; then
    echo "error: lane '${lane}' has uncommitted changes. Commit/stash, or pass --force." >&2
    exit 1
  fi
fi

echo "==> ddev delete -Oy ${project} (removes containers + volumes, keeps no snapshot)"
(cd "$lane_dir" && ddev delete -Oy) || echo "warning: ddev delete failed — check for orphaned project '${project}'." >&2

echo "==> Removing worktree ${lane_dir}"
if [[ "$force" -eq 1 ]]; then
  git worktree remove --force "$lane_dir"
else
  git worktree remove "$lane_dir"
fi

git branch -D "$lane_branch" 2>/dev/null || true
echo "==> Lane '${lane}' retired"
