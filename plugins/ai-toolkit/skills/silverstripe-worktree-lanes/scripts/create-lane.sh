#!/usr/bin/env bash
# Create a long-running worktree "lane": a persistent parallel checkout with its
# own isolated DDEV project (web + db container), a seeded database, and a built
# Silverstripe schema. Expensive setup is paid once here, then amortised across
# many tasks by reset-lane.sh.
#
# Default mode is LOCAL-ONLY: the committed .ddev/config.yaml is left untouched so
# the main checkout's URL stays load-bearing (Auth0 callbacks, CSP, Playwright).
# Each lane pins its own project name via an UNTRACKED .ddev/config.local.yaml, so
# nothing lands on the shared branch and teammates are unaffected. Pass
# --mode drop-name for the alternative that derives the name from the directory
# (requires name: removed from the committed config — see REFERENCE.md).
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: create-lane.sh <lane> [--base <ref>] [--db <dump.sql.gz>] [--root <dir>]
                              [--mode local|drop-name] [--assets none|clone|<archive>]

  <lane>         Short lane id, e.g. "a". Becomes worktree dir "<repo>-wt-<lane>".
  --base <ref>   Base ref to start the lane from    (default: origin's default branch).
  --db <file>    Canonical DB dump to import        (default: $LANE_DB_DUMP,
                 else db.sql.gz at the repo root).
  --root <dir>   Parent dir to create the worktree in (default: alongside repo).
  --mode <m>     local     (default) keep committed name:, pin per-lane project via
                           an untracked .ddev/config.local.yaml. Zero shared footprint.
                 drop-name derive the project from the directory name; requires
                           name: removed from the committed .ddev/config.yaml.
  --assets <a>   none      (default) start with an empty assets dir; prints how to
                           add them later.
                 clone     copy the main checkout's assets dir (copy-on-write clone
                           where the filesystem supports it — near-instant on APFS).
                 <archive> import a .tar.gz / .zip / dir via `ddev import-files`.

Environment overrides:
  LANE_DB_DUMP        default canonical dump path
  LANE_ASSETS_DIR     assets dir relative to the repo (default: public/assets, else assets)
  LANE_SAKE           sake invocation (default: vendor/bin/sake)
  LANE_SS_CONFIG_DIR  Silverstripe app config dir (default: app/_config)
  LANE_FLUSH_HOST     host used to flush the web process (default: <canonical>.ddev.site)
EOF
}

[[ $# -ge 1 ]] || { usage; exit 1; }
lane="$1"; shift
base=""
db="${LANE_DB_DUMP:-}"
root=""
mode="local"
assets="none"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) base="$2"; shift 2 ;;
    --db)   db="$2";   shift 2 ;;
    --root) root="$2"; shift 2 ;;
    --mode) mode="$2"; shift 2 ;;
    --assets) assets="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done
[[ "$mode" == "local" || "$mode" == "drop-name" ]] || {
  echo "error: --mode must be 'local' or 'drop-name' (got '$mode')." >&2; exit 1; }

repo_root="$(git rev-parse --show-toplevel)"
repo_name="$(basename "$repo_root")"
root="${root:-$(dirname "$repo_root")}"
lane_dir="$root/${repo_name}-wt-${lane}"
lane_branch="wt/${lane}"
db="${db:-$repo_root/db.sql.gz}"
sake="${LANE_SAKE:-vendor/bin/sake}"
ss_config_dir="${LANE_SS_CONFIG_DIR:-app/_config}"

# Assets have no one-size answer (some projects are fine blank, others carry gigabytes),
# so the caller chooses. Validate up front so a typo fails before any expensive setup.
if [[ -n "${LANE_ASSETS_DIR:-}" ]]; then
  assets_dir="$LANE_ASSETS_DIR"
elif [[ -d "$repo_root/public" ]]; then
  assets_dir="public/assets"
else
  assets_dir="assets"
fi
case "$assets" in
  none) ;;
  clone)
    [[ -d "$repo_root/$assets_dir" ]] || {
      echo "error: --assets clone, but there is no $assets_dir in $repo_root to clone." >&2; exit 1; } ;;
  *)
    [[ -e "$assets" ]] || { echo "error: --assets archive not found: $assets" >&2; exit 1; }
    assets="$(cd "$(dirname "$assets")" && pwd)/$(basename "$assets")" ;;
esac

# Default the base to origin's own default branch rather than assuming main —
# plenty of Silverstripe projects integrate on develop.
if [[ -z "$base" ]]; then
  default_branch="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's@^origin/@@' || true)"
  base="origin/${default_branch:-main}"
fi

# Read the canonical DDEV project name from the committed config. In local mode it
# stays pinned there; if absent (DDEV would derive it from the dir), fall back to
# the repo dir name. Used to name each lane and to pick the web-flush host.
canonical="$(sed -nE 's/^[[:space:]]*name:[[:space:]]*"?([^"[:space:]]+)"?.*/\1/p' "$repo_root/.ddev/config.yaml" 2>/dev/null | head -1)"
canonical="${canonical:-$repo_name}"

if [[ "$mode" == "drop-name" ]]; then
  # drop-name relies on DDEV deriving the project from the directory, so a committed
  # name: would pin every worktree to the same project — lanes then collide.
  if grep -qE '^\s*name:' "$repo_root/.ddev/config.yaml" 2>/dev/null; then
    echo "error: --mode drop-name needs 'name:' removed from .ddev/config.yaml so DDEV" >&2
    echo "       derives the project per worktree. Remove it, or use --mode local." >&2
    exit 1
  fi
  project="${repo_name}-wt-${lane}"
else
  project="${canonical}-wt-${lane}"
fi
flush_host="${LANE_FLUSH_HOST:-${canonical}.ddev.site}"

# Wire up git hooks for a freshly-created (or reset) lane. Hook managers like husky ≥9
# and lefthook point git at a generated hooks directory via core.hooksPath (e.g.
# .husky/_). That directory is gitignored, so `git worktree add` never copies it into a
# lane; core.hooksPath itself lives in the repo-local git config that every worktree
# shares, so git dutifully looks for a hooks dir that isn't there and does nothing — a
# missing hook is a silent no-op, and commits sail through with no linting or formatting.
# Regenerating it *inside the DDEV container* fails just as silently: a worktree's .git is
# a file pointing at an absolute host gitdir that isn't mounted in the container, so the
# hook manager's git calls can't resolve the gitdir and it exits quietly. So regenerate on
# the HOST, where that path resolves, then verify the hooks dir actually exists — a
# silently missing pre-commit hook is worse than a noisy one, because the first you hear of
# it is CI rejecting a branch's worth of commits.
ensure_worktree_git_hooks() {
  local dir="$1"
  [[ -f "$dir/package.json" ]] || return 0

  local hooks_path
  hooks_path="$(git -C "$dir" config --get core.hooksPath 2>/dev/null || true)"
  [[ -n "$hooks_path" ]] || return 0   # project doesn't use a core.hooksPath hook manager

  # Resolve a relative hooks path against the worktree root (git resolves core.hooksPath
  # relative to the working tree at hook time, so each lane maps to its own copy).
  local resolved="$hooks_path"
  [[ "$resolved" = /* ]] || resolved="$dir/$hooks_path"

  # Already wired up (a non-empty hooks dir) → nothing to do. Covers a reset onto a base
  # whose hooks survived the clean, and re-runs on an existing lane.
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

  echo "==> npm run prepare (host — wires up git hooks the container can't)"
  ( cd "$dir" && npm run prepare ) || true

  if [[ -d "$resolved" && -n "$(ls -A "$resolved" 2>/dev/null)" ]]; then
    echo "    git hooks wired up at ${hooks_path}"
  else
    echo "warning: git hooks still not installed at ${hooks_path} after 'npm run prepare' —" >&2
    echo "         pre-commit hooks will NOT run in this lane. Check the project's prepare" >&2
    echo "         step and core.hooksPath, then re-run it on the host." >&2
  fi
}

[[ -d "$lane_dir" ]] && { echo "error: $lane_dir already exists." >&2; exit 1; }

echo "==> Creating lane '${lane}' at ${lane_dir} (base ${base}, project ${project}, mode ${mode})"
git fetch origin --quiet || true
git worktree add -b "$lane_branch" "$lane_dir" "$base"

# Pin this lane's per-lane DDEV settings via an UNTRACKED .ddev/config.local.yaml.
# DDEV already gitignores config.local.y*ml, so this never touches the shared branch.
# Two things live here, both needed BEFORE first boot:
#   1. (local mode only) the lane's DDEV project name — drop-name instead derives it
#      from the directory, so it must NOT pin a name: here.
#   2. SS_BASE_URL, pinned to the lane host (both modes). The copied .env sets
#      SS_BASE_URL to the *main* host; a common Director::alternate_base_url mapping
#      then makes the CMS/admin build absolute URLs and redirects against the main
#      checkout — so /admin on a lane silently jumps to (and edits) main. Silverstripe's
#      .env loader is non-overloading, so this DDEV-injected value wins over the copied
#      .env without editing that secret-bearing file. Unconditional and safe: if the
#      project ignores SS_BASE_URL the var is simply unread, and https://<lane-host> is
#      exactly what SS would derive from the request host anyway.
{
  echo "# Local-only DDEV override for worktree lane '${lane}' — NOT committed."
  [[ "$mode" == "local" ]] && echo "name: ${project}"
  echo "web_environment:"
  echo "  - SS_BASE_URL=https://${project}.ddev.site"
} > "$lane_dir/.ddev/config.local.yaml"
if [[ "$mode" == "local" ]]; then
  echo "    wrote .ddev/config.local.yaml (pins project name + SS_BASE_URL=https://${project}.ddev.site)"
else
  echo "    wrote .ddev/config.local.yaml (pins SS_BASE_URL=https://${project}.ddev.site)"
fi

# Copy the untracked files each lane needs (.env, secrets). git worktree does not
# copy untracked files; .worktreeinclude lists them so the same file drives both
# these scripts and Claude Code's native worktree support.
lane_env="$lane_dir/.env"
include_file="$repo_root/.worktreeinclude"
if [[ -f "$include_file" ]]; then
  while IFS= read -r rel; do
    [[ -z "$rel" || "$rel" == \#* ]] && continue
    if [[ -e "$repo_root/$rel" ]]; then
      mkdir -p "$lane_dir/$(dirname "$rel")"
      cp -a "$repo_root/$rel" "$lane_dir/$rel"
      echo "    copied $rel"
    fi
  done < "$include_file"
elif [[ -f "$repo_root/.env" ]]; then
  cp -a "$repo_root/.env" "$lane_env"
  echo "    copied .env (no .worktreeinclude found)"
fi

# Silverstripe host allow-listing: if the project restricts hosts (AllowedHostsMiddleware
# or SS_ALLOWED_HOSTS), a fresh lane's own host is not whitelisted, so every request 400s
# "Invalid Host". Add the lane host BEFORE first boot so the initial config-manifest build
# already includes it. Only do this when the project actually restricts hosts — an empty
# AllowedHosts means "allow all", and writing a fragment would *restrict* it to the lane
# host and break the lane.
uses_env_hosts=0; uses_yaml_hosts=0
[[ -f "$lane_env" ]] && grep -qsE '^SS_ALLOWED_HOSTS=' "$lane_env" && uses_env_hosts=1
git -C "$repo_root" grep -qIE 'AllowedHostsMiddleware' -- "$ss_config_dir" 2>/dev/null && uses_yaml_hosts=1

restricts_hosts=0
if [[ "$uses_env_hosts" -eq 1 ]]; then
  # Append the lane host to the copied .env's SS_ALLOWED_HOSTS (comma-separated).
  restricts_hosts=1
  cur="$(grep -E '^SS_ALLOWED_HOSTS=' "$lane_env" | head -1 | cut -d= -f2-)"
  cur="${cur%\"}"; cur="${cur#\"}"
  new="${cur:+${cur},}${project}.ddev.site"
  tmp="$(mktemp)"
  grep -vE '^SS_ALLOWED_HOSTS=' "$lane_env" > "$tmp" || true
  echo "SS_ALLOWED_HOSTS=\"${new}\"" >> "$tmp"
  mv "$tmp" "$lane_env"
  echo "    added ${project}.ddev.site to SS_ALLOWED_HOSTS in .env"
elif [[ "$uses_yaml_hosts" -eq 1 ]]; then
  # Silverstripe's Config merges arrays across fragments, so listing just the lane host
  # here is additive — the committed AllowedHosts entries are preserved.
  restricts_hosts=1
  mkdir -p "$lane_dir/$ss_config_dir"
  cat > "$lane_dir/$ss_config_dir/lane-local.yml" <<EOF
---
Name: lane-local-allowedhosts
---
SilverStripe\\Core\\Injector\\Injector:
  SilverStripe\\Control\\Middleware\\AllowedHostsMiddleware:
    properties:
      AllowedHosts:
        - '${project}.ddev.site'
EOF
  echo "    wrote $ss_config_dir/lane-local.yml (whitelists ${project}.ddev.site)"
fi

# Clone assets on the HOST, before boot. A symlink to the main checkout's assets won't
# do: DDEV only mounts the project dir, so the link dangles inside the container. A
# copy-on-write clone (APFS clonefile on macOS, reflink on Linux) is near-instant and
# takes no extra disk until a file changes, and the lane can't touch main's files.
if [[ "$assets" == "clone" ]]; then
  echo "==> Cloning $assets_dir from the main checkout"
  mkdir -p "$lane_dir/$assets_dir"
  if [[ "$(uname)" == "Darwin" ]]; then
    cp -Rpc "$repo_root/$assets_dir/." "$lane_dir/$assets_dir/" 2>/dev/null \
      || cp -Rp "$repo_root/$assets_dir/." "$lane_dir/$assets_dir/"
  else
    cp -a --reflink=auto "$repo_root/$assets_dir/." "$lane_dir/$assets_dir/"
  fi
fi

cd "$lane_dir"
echo "==> ddev start"
ddev start
if [[ "$assets" != "none" && "$assets" != "clone" ]]; then
  echo "==> ddev import-files --source=$assets"
  ddev import-files --source="$assets"
fi
echo "==> ddev composer install (shared global cache — network-free after first lane)"
ddev composer install
# Frontend deps: only on projects that have a package.json (many SS projects are
# backend-only). DDEV shares an npm cache across projects, so this is network-cheap
# after the first lane. PUPPETEER_SKIP_DOWNLOAD guards the common arm64 failure: a
# transitive dep (e.g. mdpdf -> puppeteer) tries to fetch a Chromium binary that has
# no arm64 build, and lanes almost always run on M-series laptops. The skipped binary
# backs docs-to-PDF paths, not the dev servers; Playwright browsers live host-side.
if [[ -f package.json ]]; then
  echo "==> ddev npm install (shared npm cache — network-cheap after first lane)"
  ddev exec bash -c "PUPPETEER_SKIP_DOWNLOAD=true npm install"
  # Regenerate git hooks on the host — the in-container npm install above can't (see the
  # function comment). Run after deps are present so the hook manager binary exists.
  ensure_worktree_git_hooks "$lane_dir"
fi
if [[ -f "$db" ]]; then
  echo "==> ddev import-db --file=$db"
  ddev import-db --file="$db"
else
  echo "warning: no DB dump at $db — skipping import. Pass --db or set LANE_DB_DUMP." >&2
fi
echo "==> dev/build (once per lane)"
ddev exec "$sake" dev/build flush=1

# Belt-and-braces: force the WEB process (php-fpm) to rebuild its config manifest.
# A CLI `sake flush` only refreshes the CLI process's manifest; php-fpm can keep
# serving a stale one. Flush THROUGH the web process via a host already whitelisted.
if [[ "$restricts_hosts" -eq 1 ]]; then
  ddev exec "curl -s -o /dev/null -H 'Host: ${flush_host}' 'http://localhost/?flush=1'" || true
fi

echo "==> Lane '${lane}' ready at https://${project}.ddev.site"
if [[ "$assets" == "none" ]]; then
  echo "    No assets copied — ${assets_dir} starts empty. To add them later:"
  echo "      clone from main:   cp -Rpc '$repo_root/$assets_dir/.' '$lane_dir/$assets_dir/'"
  echo "                         (macOS; on Linux use cp -a --reflink=auto)"
  echo "      import an archive: (cd '$lane_dir' && ddev import-files --source=<assets.tar.gz>)"
fi
