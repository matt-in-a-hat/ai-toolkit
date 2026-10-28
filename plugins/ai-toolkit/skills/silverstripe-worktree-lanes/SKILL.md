---
name: silverstripe-worktree-lanes
description: Use when setting up or managing long-running git worktrees ("lanes") for parallel agents on a Silverstripe + DDEV project — creating a lane, rotating/resetting one onto a new base branch between tasks, or tearing one down. Each lane is a persistent checkout with its own isolated DDEV project and per-lane database.
---

# Silverstripe + DDEV worktree lanes

A **lane** is a *long-running* git worktree paired with its own DDEV project — a persistent
"slot" an agent works in. Unlike a throwaway per-task worktree, a lane is created once and
**rotated** onto a fresh base branch between tasks, so the expensive setup (`composer install`,
DB import, `dev/build`) is paid once per lane and amortised across many tasks.

Three operations, each backed by a script in [`scripts/`](scripts/):

- **Create** a lane — `scripts/create-lane.sh <lane>` (one-off, expensive).
- **Reset** a lane onto a new base — `scripts/reset-lane.sh <lane>` (per task, cheap).
- **Retire** a lane — `scripts/retire-lane.sh <lane>` (GC; also runs `ddev delete`).

## The one invariant: a database per lane

Silverstripe's schema is **code-driven** — `dev/build` reconstructs it from the `DataObject`
classes on the current branch. Two lanes on different branches imply different schemas, so a
**shared database is corruption, not a merge conflict**: whichever lane runs `dev/build` last
silently reshapes the schema under the others. A separate database per lane is therefore
**mandatory**. The chosen mechanism — one DDEV project per worktree — gives each lane its own
web *and* db container for free, so this invariant holds without any manual port or DB-name
juggling. Never point two lanes at one database.

## Prerequisites (once per repo)

The default **local-only** mode is designed to just work on the common Silverstripe shape with
**no committed changes** — the scripts pin each lane's DDEV project and whitelist its host
through untracked local files. Only a couple of things are worth setting up first;
[`REFERENCE.md`](REFERENCE.md) has the exact templates:

1. **Add a `.worktreeinclude`** listing the untracked files each lane needs (`.env`, secrets).
   The scripts copy these into every new lane, and Claude Code's native worktrees honour the
   same file.
2. **Keep one canonical `db.sql.gz`** the scripts import per lane (default: repo-root
   `db.sql.gz`, or set `LANE_DB_DUMP`).
3. *(optional)* **Gitignore the lane machinery** so it stays invisible to `git status`.
   DDEV already gitignores `.ddev/config.local.yaml`; add `app/_config/lane-local.yml`,
   `.worktreeinclude`, and (if not already) `db.sql.gz` to `.git/info/exclude`.

The scripts defuse three Silverstripe-specific traps for you — the per-lane DDEV project name,
the `AllowedHosts` 400, and the `/admin` host-jump — and default `--base` to origin's own default
branch. Read the matching section of [`REFERENCE.md`](REFERENCE.md) when a lane misbehaves, not
before; `--mode drop-name` and the rationale for each trap live there.

## Steps

1. **Confirm the prerequisites above are met.** Check a `.worktreeinclude` exists and a
   canonical DB dump is reachable. Fix any gap using `REFERENCE.md` before creating a lane —
   local mode needs no `.ddev/config.yaml` edit.
2. **Create or reset the lane.** For a brand-new slot run `scripts/create-lane.sh <lane>
   [--base <ref>] [--db <dump>]`. For an existing slot starting a new task run
   `scripts/reset-lane.sh <lane> [--base <ref>]` — it guards against discarding uncommitted or
   unpushed work. Done when the script reports the lane ready, `ddev describe` shows the project
   running, and the lane's own host serves the site — including `/admin`, which must stay on the
   lane host, never the main one.
3. **Work in the lane, one task per lane.** Keep each lane scoped to a single task so its
   branch, DB state, and containers stay coherent; start the next task by resetting the lane,
   not by piling a second task into it.
4. **Retire when done with the slot.** Run `scripts/retire-lane.sh <lane>` — it runs
   `ddev delete` *before* removing the worktree so no orphaned containers/volumes are left.
   Done when both the DDEV project and the worktree are gone.

## Lifecycle & limits

- **Idle a lane, don't destroy it:** `ddev stop` a lane you'll return to (preserves its DB and
  volumes) and `ddev start` to resume — far cheaper than retire + recreate.
- **Practical ceiling ~2–3 live lanes** on a laptop: `dev/build` and the per-lane web
  container are CPU-heavy. Stop idle lanes to stay under it.
- Deeper rationale, per-lane cost mitigations, the DB-engine caveat, and the stale
  `index.lock` gotcha live in [`REFERENCE.md`](REFERENCE.md).
