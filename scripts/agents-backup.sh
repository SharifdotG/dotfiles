#!/usr/bin/env bash
# Export and re-import the part of ~/.claude that you cannot regenerate:
# MCP server definitions, global skills, rules and settings.
#
# WHAT THIS DELIBERATELY DOES NOT DO: copy ~/.claude wholesale. It is 294 MB, of
# which 249 MB is `projects/` (conversation transcripts) and 37 MB is `plugins/`
# (a re-installable cache). The config that actually matters is a few megabytes,
# and ~/.claude.json - 79 KB - is mostly this machine's identity: machineID,
# userID, onboarding flags, per-project history, cached feature flags. Restoring
# those onto a fresh install carries the old machine's identity with them.
#
# THE EXPORT CONTAINS LIVE API KEYS AND BEARER TOKENS - that is the point, since
# the ask is to restore immediately rather than re-authenticate nine servers. It
# is written 0700/0600 and belongs with the other credential material from
# MIGRATION.md Stage 2, not on the external drive alone.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

CFG="${CLAUDE_CONFIG:-$HOME/.claude.json}"   # overridable so restore can be rehearsed against a copy
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
AGENTS_DIR="${AGENTS_DIR:-$HOME/.agents}"
DEFAULT_OUT="$HOME/Backup/claude"
MODE=""; DIR=""; FORCE=0

usage() {
  cat <<'EOS'
usage: scripts/claude-backup.sh export  [-o DIR]     # default ~/Backup/claude
       scripts/claude-backup.sh restore [-i DIR] [--force]
       scripts/claude-backup.sh show    [-i DIR]     # what is in an export, keys redacted

What moves:
  mcp-servers.json     ~/.claude.json's mcpServers, user scope and project scope
  skills.tar.gz        ~/.claude/skills - symlinks preserved, broken ones dropped
  agents-skills.tar.gz ~/.agents/skills - what those symlinks point at
  config.tar.gz        settings.json, settings.local.json, rules/, and the
                       installed-plugin LISTS (not the 37 MB plugin cache)

  --force   overwrite whatever already exists on the target. Without it the
            existing file or skill wins and is reported as skipped, on the
            principle that what is already there was put there deliberately.
EOS
  exit "${1:-0}"
}

case "${1:-}" in
  export|restore|show) MODE="$1"; shift ;;
  -h|--help|'') usage 0 ;;
  *) warn "unknown command: $1"; usage 1 ;;
esac
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out|-i|--in) DIR="${2:-}"; [ -n "$DIR" ] || die "$1 needs a path"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage 0 ;;
    *) warn "unknown argument: $1"; usage 1 ;;
  esac
done
[ -n "$DIR" ] || DIR="$DEFAULT_OUT"

command -v jq >/dev/null || die "jq is required (packages/core.tsv installs it)"

# ── export ───────────────────────────────────────────────────────────────────
if [ "$MODE" = export ]; then
  UI_STEPS=4
  banner "Claude config export" "$DIR"
  [ -r "$CFG" ] || die "no $CFG on this machine"
  (umask 077 && mkdir -p "$DIR") || die "cannot create $DIR"
  chmod 700 "$DIR" 2>/dev/null

  step "MCP servers"
  n_user=$(jq '.mcpServers // {} | length' "$CFG")
  n_proj=$(jq '[.projects // {} | to_entries[] | select((.value.mcpServers // {}) | length > 0)] | length' "$CFG")
  if (umask 077 && jq -n \
      --arg at "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" --arg host "$(uname -n)" \
      --slurpfile c "$CFG" '{
        exported: $at, host: $host,
        user: ($c[0].mcpServers // {}),
        projects: ($c[0].projects // {} | with_entries(select((.value.mcpServers // {}) | length > 0))
                   | map_values(.mcpServers))
      }' > "$DIR/mcp-servers.json"); then
    chmod 600 "$DIR/mcp-servers.json"
    ok "$n_user user-scope, $n_proj project(s) with their own -> mcp-servers.json"
  else
    die "could not write mcp-servers.json"
  fi
  # A stdio server whose command is gone will fail on every session start of the
  # new machine. Better to see it now than to debug it there.
  while IFS=$'\t' read -r name cmd; do
    [ -n "$cmd" ] && [ "$cmd" != null ] || continue
    command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ] ||
      warn "$name: stdio command not found here - '$cmd'"
  done < <(jq -r '.user | to_entries[] | select((.value.type // "stdio") == "stdio")
                  | [.key, (.value.command // "")] | @tsv' "$DIR/mcp-servers.json")

  step "Global skills"
  # THE TRAP THIS STEP EXISTS FOR. ~/.claude/skills is three different things
  # wearing one directory: real directories, RELATIVE symlinks into
  # ~/.agents/skills, and ABSOLUTE symlinks to /c/Users/... left over from the
  # Windows machine. `/c` does not exist here, so those are already dead - and a
  # plain `tar` would faithfully archive fourteen dangling links and restore
  # them, still dead, on the new machine.
  #
  # So: broken links are dropped and named, working links are kept AS LINKS, and
  # ~/.agents/skills is archived alongside so they still resolve after restore.
  if [ -d "$CLAUDE_DIR/skills" ]; then
    LIST=$(mktemp); DEAD=0; KEPT=0
    for f in "$CLAUDE_DIR"/skills/*; do
      [ -e "$f" ] || [ -L "$f" ] || continue
      b=$(basename "$f")
      if [ -L "$f" ] && [ ! -e "$f" ]; then
        warn "dropping dead skill link: $b -> $(readlink "$f")"; DEAD=$((DEAD+1)); continue
      fi
      printf '%s\n' "$b" >> "$LIST"; KEPT=$((KEPT+1))
    done
    if [ "$KEPT" -gt 0 ] && (umask 077 && tar czf "$DIR/skills.tar.gz" \
         -C "$CLAUDE_DIR/skills" -T "$LIST" 2>/dev/null); then
      ok "$KEPT skill(s) -> skills.tar.gz  ($(du -h "$DIR/skills.tar.gz" | cut -f1)), $DEAD dead link(s) dropped"
    else
      warn "no skills archived"
    fi
    rm -f "$LIST"
  else
    ok "no $CLAUDE_DIR/skills"
  fi
  if [ -d "$AGENTS_DIR/skills" ]; then
    (umask 077 && tar czf "$DIR/agents-skills.tar.gz" -C "$AGENTS_DIR" skills 2>/dev/null) &&
      ok "$AGENTS_DIR/skills -> agents-skills.tar.gz  ($(du -h "$DIR/agents-skills.tar.gz" | cut -f1))" ||
      warn "could not archive $AGENTS_DIR/skills"
  fi

  step "Settings, rules and the plugin list"
  LIST=$(mktemp)
  for rel in settings.json settings.local.json rules CLAUDE.md \
             plugins/installed_plugins.json plugins/known_marketplaces.json; do
    [ -e "$CLAUDE_DIR/$rel" ] && printf '%s\n' "$rel" >> "$LIST"
  done
  if [ -s "$LIST" ] && (umask 077 && tar czf "$DIR/config.tar.gz" -C "$CLAUDE_DIR" -T "$LIST" 2>/dev/null); then
    chmod 600 "$DIR/config.tar.gz"
    ok "$(wc -l < "$LIST") item(s) -> config.tar.gz"
    sed 's/^/      /' "$LIST"
  else
    warn "nothing to put in config.tar.gz"
  fi
  rm -f "$LIST"

  steps_end
  rule
  n_secret=$(jq '[.user[] | select((.headers // {} | length) > 0 or (.env // {} | length) > 0)] | length' "$DIR/mcp-servers.json")
  warn "$n_secret MCP server(s) carry credentials here. 0600; keep it off the repo"
  info "Restore on the new machine: ./scripts/claude-backup.sh restore -i '$DIR'"
  exit 0
fi

[ -d "$DIR" ] || die "no export directory at $DIR"
[ -r "$DIR/mcp-servers.json" ] || die "$DIR does not look like a claude-backup.sh export"

# ── show ─────────────────────────────────────────────────────────────────────
if [ "$MODE" = show ]; then
  banner "Claude config export" "$DIR"
  info "taken $(jq -r '.exported' "$DIR/mcp-servers.json") on $(jq -r '.host' "$DIR/mcp-servers.json")"
  rule
  info "MCP servers, user scope"
  jq -r '.user | to_entries[] | [.key, (.value.type // "stdio"), (.value.url // .value.command // ""),
         (((.value.headers // {}) | keys) + ((.value.env // {}) | keys) | join(","))] | @tsv' "$DIR/mcp-servers.json" |
    awk -F'\t' '{ printf "    %-30s %-6s %-46s %s\n", $1, $2, substr($3,1,46), ($4 ? "creds: " $4 : "") }'
  info "MCP servers, project scope"
  jq -r '.projects | to_entries[] | "    \(.key): \(.value | keys | join(", "))"' "$DIR/mcp-servers.json"
  for t in skills agents-skills config; do
    [ -r "$DIR/$t.tar.gz" ] || continue
    info "$t.tar.gz  ($(du -h "$DIR/$t.tar.gz" | cut -f1))"
    tar tzf "$DIR/$t.tar.gz" | awk -F/ '{print $1}' | sort -u | sed 's/^/      /' | head -40
  done
  exit 0
fi

# ── restore ──────────────────────────────────────────────────────────────────
UI_STEPS=5
banner "Claude config restore" "$DIR"

step "Preflight"
[ -r "$CFG" ] || die "no $CFG - run 'claude' once first so the file exists, then re-run"
jq -e . "$DIR/mcp-servers.json" >/dev/null 2>&1 || die "mcp-servers.json is not valid JSON"
pgrep -x claude >/dev/null 2>&1 &&
  warn "a claude process is running - it may rewrite ~/.claude.json and undo this. Quit it first."
ok "$CFG present"

step "Backing up the current config"
BAK="$CFG.bak.$(date -u +%Y%m%dT%H%M%SZ)"
cp -p "$CFG" "$BAK" && chmod 600 "$BAK" && ok "$BAK" || die "could not back up $CFG"

step "MCP servers, user scope"
# Existing wins unless --force: a server already configured here was configured
# deliberately, and this export is by definition the older opinion.
ADDED=$(jq -r --slurpfile e "$DIR/mcp-servers.json" --argjson force "$FORCE" '
  ($e[0].user // {}) as $new | (.mcpServers // {}) as $cur
  | [ $new | keys[] | select($force == 1 or ($cur[.] | not)) ] | join(" ")' "$CFG")
SKIPPED=$(jq -r --slurpfile e "$DIR/mcp-servers.json" --argjson force "$FORCE" '
  ($e[0].user // {}) as $new | (.mcpServers // {}) as $cur
  | [ $new | keys[] | select($force != 1 and ($cur[.] | type) == "object") ] | join(" ")' "$CFG")
TMP=$(mktemp) || die "mktemp failed"
if (umask 077 && jq --slurpfile e "$DIR/mcp-servers.json" --argjson force "$FORCE" '
      ($e[0].user // {}) as $new
      | .mcpServers = (if $force == 1 then (.mcpServers // {}) * $new
                                      else $new * (.mcpServers // {}) end)' "$CFG" > "$TMP") &&
   jq -e . "$TMP" >/dev/null 2>&1; then
  cat "$TMP" > "$CFG"; chmod 600 "$CFG"; rm -f "$TMP"
else
  rm -f "$TMP"; die "merge produced invalid JSON - $CFG untouched, backup at $BAK"
fi
for s in $ADDED;   do ok   "added   $s"; done
for s in $SKIPPED; do note "$s" "already configured, left alone"; done
[ -n "$ADDED$SKIPPED" ] || warn "the export had no user-scope servers"

# Project keys are absolute paths. Most will not exist here (some are Windows
# paths from an older machine), so only real directories are merged - the rest
# are reported, not silently dropped.
while IFS=$'\t' read -r path names; do
  if [ -d "$path" ]; then
    TMP=$(mktemp)
    if (umask 077 && jq --slurpfile e "$DIR/mcp-servers.json" --arg p "$path" --argjson force "$FORCE" '
          ($e[0].projects[$p] // {}) as $new
          | .projects[$p] = ((.projects[$p] // {}) +
              { mcpServers: (if $force == 1 then ((.projects[$p].mcpServers // {}) * $new)
                                            else ($new * (.projects[$p].mcpServers // {})) end) })' \
          "$CFG" > "$TMP") && jq -e . "$TMP" >/dev/null 2>&1; then
      cat "$TMP" > "$CFG"; rm -f "$TMP"; ok "project $path -> $names"
    else
      rm -f "$TMP"; warn "$path: merge failed, skipped"
    fi
  else
    note "$(basename "$path")" "no such directory here - not merged ($names)"
  fi
done < <(jq -r '.projects | to_entries[] | [.key, (.value | keys | join(", "))] | @tsv' "$DIR/mcp-servers.json")

step "Skills"
# --skip-old-files is the tar spelling of "existing wins". With --force we let
# tar overwrite instead.
XOPT="--skip-old-files"; [ "$FORCE" -eq 1 ] && XOPT="--overwrite"
if [ -r "$DIR/agents-skills.tar.gz" ]; then
  mkdir -p "$AGENTS_DIR" &&
  tar xzf "$DIR/agents-skills.tar.gz" -C "$AGENTS_DIR" $XOPT 2>/dev/null &&
    ok "$AGENTS_DIR/skills" || warn "$AGENTS_DIR/skills: extract failed"
fi
if [ -r "$DIR/skills.tar.gz" ]; then
  mkdir -p "$CLAUDE_DIR/skills" &&
  tar xzf "$DIR/skills.tar.gz" -C "$CLAUDE_DIR/skills" $XOPT 2>/dev/null &&
    ok "$CLAUDE_DIR/skills  ($(find "$CLAUDE_DIR/skills" -maxdepth 1 -mindepth 1 | wc -l) entries)" ||
    warn "$CLAUDE_DIR/skills: extract failed"
  # The relative links only resolve once ~/.agents/skills is in place; say so
  # rather than leaving a skill that silently never loads.
  D=0
  for f in "$CLAUDE_DIR"/skills/*; do
    [ -L "$f" ] && [ ! -e "$f" ] && { warn "still dangling: $(basename "$f") -> $(readlink "$f")"; D=$((D+1)); }
  done
  [ "$D" -eq 0 ] && ok "every restored skill resolves"
fi

step "Settings, rules and the plugin list"
if [ -r "$DIR/config.tar.gz" ]; then
  mkdir -p "$CLAUDE_DIR" &&
  tar xzf "$DIR/config.tar.gz" -C "$CLAUDE_DIR" $XOPT 2>/dev/null &&
    ok "settings, rules and plugin lists restored" || warn "config.tar.gz: extract failed"
  # The plugin CACHE is deliberately not carried across - 37 MB of it, and some
  # entries still record a `C:\\Users\\...` installPath from the Windows machine.
  # The list is what you want; `/plugin install` rebuilds the rest.
  if [ -r "$CLAUDE_DIR/plugins/installed_plugins.json" ]; then
    info "Plugins are NOT restored. Reinstall these with /plugin install <name>:"
    jq -r '.plugins // {} | keys[]' "$CLAUDE_DIR/plugins/installed_plugins.json" 2>/dev/null |
      sed 's/^/      /'
  fi
else
  ok "no config.tar.gz in this export"
fi

steps_end
rule
info "Verify with:  claude mcp list   and   /skills inside claude"
info "Previous ~/.claude.json kept at $BAK"
