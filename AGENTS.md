## What this is

A personal **Claude Code plugin marketplace** (`matt-in-a-hat`) holding one plugin
(`ai-toolkit`). It is **not** an application — there is no build, no dependencies, no
runtime. Everything is Markdown, JSON config, and the shell scripts a skill ships.

**Critical rule:** only `plugin.json` goes inside a plugin's `.claude-plugin/` folder.
`skills/`, `agents/`, `hooks/`, `.mcp.json`, `settings.json` all live at the plugin
**root**, never inside `.claude-plugin/`.

## Conventions

- **`AGENTS.md` is canonical** — `CLAUDE.md` contains only `@AGENTS.md`.
- **New Zealand English** — "organise", "standardised", "colour".
- **kebab-case** filenames and skill directory names.
- **Skill frontmatter** — every `SKILL.md` needs a `name` and a specific `description`;
  the `description` is what the model matches on to auto-invoke, so make it concrete
  ("Use when ...").
- **Permissions can't ship in a plugin** — a plugin `settings.json` only honours the
  `agent` and `subagentStatusLine` keys. Default permissions belong in
  `shared/settings.template.json` and are applied by a human via `install.sh --settings`.
- **No `version` in `plugin.json`** — without one, the git commit SHA is used and every
  push to `main` counts as an update. Don't add one unless you also take on bumping it.

## Common tasks

- **Add a skill**: create `plugins/ai-toolkit/skills/<name>/SKILL.md`, then update the
  plugin README table.
- **Test locally**: `claude --plugin-dir ./plugins/ai-toolkit`, then `/reload-plugins`.
- **Validate**: `claude plugin validate .` before committing.

## Git conventions

Conventional commits: `feat`, `fix`, `docs`, `chore`.
Example: `feat(ai-toolkit): add <skill> skill`.
