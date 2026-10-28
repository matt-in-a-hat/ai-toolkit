# ai-toolkit

Reusable skills for Claude Code.

## Skills

| Skill | Invoke | Purpose |
| :---- | :----- | :------ |
| `silverstripe-worktree-lanes` | `/ai-toolkit:silverstripe-worktree-lanes` (or model-invoked) | Set up and manage long-running git worktree "lanes" for parallel agents on a Silverstripe + DDEV project — create, reset onto a new base, or retire a lane, each with its own isolated DDEV project and per-lane database. Ships `create`/`reset`/`retire` scripts and discloses rationale to `REFERENCE.md`. |

## Adding a skill to this plugin

1. Create `skills/<skill-name>/SKILL.md`.
2. Add YAML frontmatter with a `name` and a `description` (the `description` is what the
   model matches on to decide when to auto-invoke — make it specific).
3. Write the instructions as the body.
4. Run `/reload-plugins` in a session that has this plugin loaded to pick it up.
5. Add a row to the table above.

See the repo root [README](../../README.md) for how this plugin is distributed.
