#!/usr/bin/env bash
#
# install.sh — set up the ai-toolkit for use with Claude Code.
#
# By default this only registers the marketplace — the safe part that an agent
# (Claude Code) can run for you:
#   1. Registers this repo as a Claude Code plugin marketplace (so you can
#      /plugin install ai-toolkit@matt-in-a-hat in any project).
#
# The shared default permissions (shared/settings.template.json) are NOT merged
# by default. Claude Code's self-modification guardrail blocks an agent from
# writing permission rules into a settings.json, so that step only works when a
# HUMAN runs it. Opt in with --settings, and it targets the CURRENT PROJECT
# (./.claude/settings.json) unless you pass --global.
#
# Usage:
#   ./install.sh                       # register the marketplace only (agent-safe)
#   ./install.sh --settings            # + merge defaults into ./.claude/settings.json (run this yourself)
#   ./install.sh --settings --project /path   # merge into /path/.claude/settings.json
#   ./install.sh --settings --global   # merge into ~/.claude/settings.json (explicit opt-in)
#   ./install.sh --no-marketplace --settings  # only merge settings
#
# Prefer to do it by hand? shared/settings.template.json is a plain reference —
# copy the tiers you want into a project's .claude/settings.json yourself.
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$REPO_DIR/shared/settings.template.json"
MARKETPLACE="matt-in-a-hat/ai-toolkit"

DO_MARKETPLACE=true
DO_SETTINGS=false
DO_GLOBAL=false
PROJECT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --settings)      DO_SETTINGS=true; shift ;;
    --global)        DO_GLOBAL=true; shift ;;
    --project)       PROJECT_DIR="${2:?--project needs a path}"; shift 2 ;;
    --no-settings)   DO_SETTINGS=false; shift ;;
    --no-marketplace) DO_MARKETPLACE=false; shift ;;
    -h|--help)       sed -n '2,29p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# 1. Register the marketplace ------------------------------------------------
if $DO_MARKETPLACE; then
  if command -v claude >/dev/null 2>&1; then
    echo "==> Registering marketplace '$MARKETPLACE'"
    claude plugin marketplace add "$MARKETPLACE" || \
      echo "    (already registered or add failed — continuing)"
    echo "    Install plugins with:  claude plugin install ai-toolkit@matt-in-a-hat"
  else
    echo "==> 'claude' CLI not found. To register the marketplace, run this inside Claude Code:"
    echo "    /plugin marketplace add $MARKETPLACE"
  fi
fi

# 2. Merge shared permissions (opt-in, human-run) ----------------------------
if $DO_SETTINGS; then
  echo "==> NOTE: merging permission rules must be done by a human — Claude Code's"
  echo "    self-modification guardrail blocks an agent from writing them for you."

  if [[ -n "$PROJECT_DIR" ]]; then
    TARGET="$PROJECT_DIR/.claude/settings.json"
  elif $DO_GLOBAL; then
    TARGET="$HOME/.claude/settings.json"
  else
    TARGET="$PWD/.claude/settings.json"
  fi
  mkdir -p "$(dirname "$TARGET")"

  if ! command -v jq >/dev/null 2>&1; then
    echo "==> jq is required to merge settings (brew install jq). Skipping settings." >&2
    exit 1
  fi

  echo "==> Merging default permissions into $TARGET"
  if [[ -f "$TARGET" ]]; then
    cp "$TARGET" "$TARGET.bak"
    echo "    Backed up existing settings to $TARGET.bak"
  else
    echo '{}' > "$TARGET"
  fi

  # Deep-merge: template wins on scalars; permission arrays are unioned.
  jq -s '
    (.[0] // {}) as $cur | (.[1] // {}) as $tpl |
    ($cur * $tpl) |
    del(.["$comment"], .["_comment"]) |
    .permissions.allow = (($cur.permissions.allow // []) + ($tpl.permissions.allow // []) | unique) |
    .permissions.ask   = (($cur.permissions.ask   // []) + ($tpl.permissions.ask   // []) | unique) |
    .permissions.deny  = (($cur.permissions.deny  // []) + ($tpl.permissions.deny  // []) | unique)
  ' "$TARGET" "$TEMPLATE" > "$TARGET.tmp" && mv "$TARGET.tmp" "$TARGET"

  echo "    Done. Review with:  cat \"$TARGET\""
else
  echo "==> Settings not touched. To merge the shared defaults yourself, run:"
  echo "    ./install.sh --settings            (into ./.claude/settings.json — this project)"
  echo "    ./install.sh --settings --global   (into ~/.claude/settings.json)"
  echo "    ...or copy the tiers you want from shared/settings.template.json by hand."
fi

echo "==> Finished."
