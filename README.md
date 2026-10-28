# ai-toolkit

A personal **Claude Code plugin marketplace** of reusable skills.

Register this repo once as a marketplace, then install the plugin wherever you want it.
Updates are a single command.

## Install

```bash
# One-time, per machine — register the marketplace
claude plugin marketplace add matt-in-a-hat/ai-toolkit
#   ...or inside a Claude Code session:  /plugin marketplace add matt-in-a-hat/ai-toolkit

# Per project (or globally) — install the plugin
claude plugin install ai-toolkit@matt-in-a-hat
#   ...or inside a session:  /plugin install ai-toolkit@matt-in-a-hat
```

Or clone and run `./install.sh`, which only registers the marketplace by default.

### Shared permission defaults

`shared/settings.template.json` holds permission defaults (allow read-only git/gh/ddev
commands, ask before commit/push/PR, deny `curl`/`wget`, force-push and reading `.env`
or secrets). Plugins can't ship permissions, so apply them yourself — a **human must run
this**, as Claude Code's self-modification guardrail blocks an agent from writing
permission rules:

```bash
./install.sh --no-marketplace --settings   # merge into ./.claude/settings.json (this repo)
./install.sh --settings --project /path/to/repo   # into another project
./install.sh --settings --global   # into ~/.claude/settings.json (explicit opt-in)
```

Or copy the tiers you want into a `.claude/settings.json` by hand.

## Update

```bash
claude plugin marketplace update matt-in-a-hat
#   ...or inside a session:  /plugin marketplace update matt-in-a-hat
```

The plugin has no `version` field, so every commit pushed to `main` counts as an update.

## What's here

```
ai-toolkit/
├── .claude-plugin/
│   └── marketplace.json        # the catalogue — lists every plugin below
├── plugins/
│   └── ai-toolkit/
│       ├── .claude-plugin/plugin.json
│       ├── skills/<name>/SKILL.md
│       └── README.md
├── shared/
│   └── settings.template.json  # default permissions (applied separately — see above)
└── install.sh
```

| Plugin | Install | Contents |
| :----- | :------ | :------- |
| `ai-toolkit` | `ai-toolkit@matt-in-a-hat` | `silverstripe-worktree-lanes`. See [plugins/ai-toolkit](plugins/ai-toolkit/README.md). |

## Developing

- **Add a skill** — add `plugins/ai-toolkit/skills/<name>/SKILL.md` with `name` +
  `description` frontmatter, and a row in the plugin README.
- **Test locally without installing** — `claude --plugin-dir ./plugins/ai-toolkit`, then
  `/reload-plugins` after edits.
- **Validate before pushing** — `claude plugin validate .`

See [AGENTS.md](AGENTS.md) for conventions (`CLAUDE.md` just imports it).

## Credit

Derived from [jooleearr/ai-toolkit](https://github.com/jooleearr/ai-toolkit), keeping only
the `silverstripe-worktree-lanes` skill. Credit and thanks to the original author.
