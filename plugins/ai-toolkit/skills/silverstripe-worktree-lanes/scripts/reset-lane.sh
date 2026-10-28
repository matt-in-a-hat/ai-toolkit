#!/usr/bin/env bash
# Rotate an existing lane onto a fresh base branch for a new task — the cheap,
# repeated operation. Reuses the lane's DDEV project, container, and vendor dir;
# only re-seeds the database and rebuilds the schema. Refuses to clobber
# uncommitted or unpushed work.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: reset-lane.sh <lane> [--base <ref>] [--db <dump.sql.gz>] [--root <dir>] [--force]

  <lane>         Short lane id, e.g. "a" (the existing lane to rotate).
  --base <ref>   Base ref to reset onto              (default: origin's default branch).
  --db <file>    Canonical DB dump to re-import       (default: $LANE_DB_DUMP,
                 else db.sql.gz at the repo root).
  --root <dir>   Parent dir the worktree lives in     (default: alongside repo).
  --force        Skip the uncommitted/unpushed-work guard.

Environment overrides: LANE_DB_DUMP, LANE_SAKE (default vendor/bin/sake),
LANE_SS_CONFIG_DIR (default app/_config), LANE_FLUSH_HOST.
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
lane="$1"; shift
base=""
db="${LANE_DB_DUMP:-}"
root=""
force=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --db)   db="$2";   shift 2 ;;
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
db="${db:-$repo_root/db.sql.gz}"
sake="${LANE_SAKE:-vendor/bin/sake}"
ss_config_dir="${LANE_SS_CONFIG_DIR:-app/_config}"

# Default the base to origin's own default branch rather than assuming main.
if [[ -z "$base" ]]; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  base="origin/${default_branch:-main}"
fi

# Web-flush host + whether this project restricts hosts at all (mirrors create-lane).
canonical="$(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$repo_root/.ddev/config.yaml" 2>/dev/null | head -1)"
canonical="${canonical:-$repo_name}"
flush_host="${LANE_FLUSH_HOST:-${canonical}.ddev.site}"
restricts_hosts=0
{ [[ -f "$lane_dir/.env" ]] && grep -qsE '^SS_ALLOWED_HOSTS=' "$lane_dir/.env"; } && restricts_hosts=1
git -C "$repo_root" grep -qIE 'AllowedHostsMiddleware' -- "$ss_config_dir" 2>/dev/null && restricts_hosts=1

# Wire up git hooks for the lane after a reset. `git clean -fd` (no -x) below leaves the
# gitignored generated hooks dir in place, so this is usually a no-op — but it repairs a
# lane created before hook-wiring existed, or one whose new base changes the hook config.
# See create-lane.sh for why regenerating must happen on the host, not in the container.
ensure_worktree_git_hooks() {
  local dir="$1"
  [[ -f "$dir/package.json" ]] || return 0

  local hooks_path
  hooks_path="$(git -C "$dir" config --get core.hooksPath 2>/dev/null || true)"
  [[ -n "$hooks_path" ]] || return 0   # project doesn't use a core.hooksPath hook manager

  local resolved="$hooks_path"
  [[ "$resolved" = /* ]] || resolved="$dir/$hooks_path"

  if [[ -d "$resolved" && -n "$(ls -A "$resolved" 2>/dev/null)" ]]; then
    return 0
  fi

  if ! grep -qE '"prepare"[[:space:]]*:' "$dir/package.json"; then
    echo "warning: lane uses core.hooksPath=${hooks_path} but its hooks dir is missing and" >&2
    echo "         package.json has no 'prepare' script to regenerate it — git hooks (e.g." >&2
    echo "         pre-commit linting) will NOT run in this lane. Wire them up by hand." >&2
    return 0
  fi
  if ! command -v npm >/dev/null 2>&1; then
    echo "warning: git hooks need regenerating on the host (core.hooksPath=${hooks_path})," >&2
    echo "         but no host 'npm' was found. Run 'npm run prepare' in ${dir} yourself, or" >&2
    echo "         git hooks will NOT run in this lane." >&2
    return 0
  fi

  echo "==> npm run prepare (host — re-wires git hooks the container can't)"
  ( cd "$dir" && npm run prepare ) || true

  if [[ -d "$resolved" && -n "$(ls -A "$resolved" 2>/dev/null)" ]]; then
    echo "    git hooks wired up at ${hooks_path}"
  else
    echo "warning: git hooks still not installed at ${hooks_path} after 'npm run prepare' —" >&2
    echo "         pre-commit hooks will NOT run in this lane. Check the project's prepare" >&2
    echo "         step and core.hooksPath, then re-run it on the host." >&2
  fi
}

[[ -d "$lane_dir" ]] || { echo "error: no lane at $lane_dir — create it first." >&2; exit 1; }
cd "$lane_dir"

# Rotating discards the working tree. Guard the two ways real work can be lost:
# uncommitted changes, and committed-but-unpushed commits.
if [[ "$force" -ne 1 ]]; then
  if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: lane '${lane}' has uncommitted changes. Commit/stash, or pass --force." >&2
    git status --short >&2
    exit 1
  fi
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)"
  if [[ -n "$upstream" ]]; then
    unpushed="$(git log --oneline @{u}.. 2>/dev/null || true)"
    if [[ -n "$unpushed" ]]; then
      echo "error: lane '${lane}' has unpushed commits. Push them, or pass --force." >&2
      echo "$unpushed" >&2
      exit 1
    fi
  fi
fi

echo "==> Rotating lane '${lane}' onto ${base}"
git fetch origin --quiet || true
git switch -C "$lane_branch" "$base"
# Preserve the untracked per-lane machinery across the clean. config.local.yaml is
# gitignored by DDEV so it survives anyway, but lane-local.yml may not be — exclude
# both explicitly so a reset never strips the lane's project name or host whitelist.
git clean -fd -e .ddev/config.local.yaml -e "$ss_config_dir/lane-local.yml"

if [[ -f "$db" ]]; then
  echo "==> Re-importing DB from $db"
  ddev import-db --file="$db"
else
  echo "warning: no DB dump at $db — skipping import." >&2
fi
echo "==> dev/build flush=1"
ddev exec "$sake" dev/build flush=1

# Reset rebuilds over a WARM cache, so the web process keeps serving its stale config
# manifest until flushed through the web process itself — here this is load-bearing,
# not just belt-and-braces. Flush via a host that is already whitelisted.
if [[ "$restricts_hosts" -eq 1 ]]; then
  ddev exec "curl -s -o /dev/null -H 'Host: ${flush_host}' 'http://localhost/?flush=1'" || true
fi

# Repair git hooks if the reset (or a pre-fix lane) left them unwired.
ensure_worktree_git_hooks "$lane_dir"

echo "==> Lane '${lane}' reset onto ${base} and ready"
