#!/usr/bin/env bash
# Export the agent configuration you cannot regenerate, and restore it into
# ALL THREE agents that run on this machine: Claude Code, Codex, and Antigravity.
#
# One export, three restores. The source of truth is Claude Code (~/.claude.json
# and ~/.claude/skills); Codex and Antigravity get the same servers and the same
# skills translated into the shape each of them actually reads:
#
#   Claude Code   ~/.claude.json          .mcpServers            JSON
#   Codex         ~/.codex/config.toml    [mcp_servers.<name>]   TOML
#   Antigravity   ~/.gemini/config/mcp_config.json  .mcpServers  JSON
#
# Skills are installed ONCE into ~/.agents/skills and symlinked into each agent's
# skills directory - which is the pattern this machine already uses for 13 of its
# skills, and it means editing a skill updates it everywhere instead of leaving
# three copies to drift.
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
AGENTS_DIR="${AGENTS_DIR:-$HOME/.agents}"           # the shared skill store
CODEX_DIR="${CODEX_DIR:-$HOME/.codex}"
GEMINI_DIR="${GEMINI_DIR:-$HOME/.gemini}"           # Antigravity lives under here
DEFAULT_OUT="$HOME/Backup/claude"
MODE=""; DIR=""; FORCE=0; ONLY_AGENTS="claude,codex,antigravity"; KEEP_DEAD=0

usage() {
  cat <<'EOS'
usage: scripts/agents-backup.sh export  [-o DIR]     # default ~/Backup/claude
       scripts/agents-backup.sh restore [-i DIR] [--agents LIST] [--all] [--force]
       scripts/agents-backup.sh show    [-i DIR]     # what is in an export, keys redacted

What moves:
  mcp-servers.json     ~/.claude.json's mcpServers, user scope and project scope
  skills.tar.gz        ~/.claude/skills - symlinks preserved, broken ones dropped
  agents-skills.tar.gz ~/.agents/skills - what those symlinks point at
  config.tar.gz        settings.json, settings.local.json, rules/, and the
                       installed-plugin LISTS (not the 37 MB plugin cache)

Restore targets Claude Code, Codex and Antigravity by default.

  --agents LIST  comma-separated subset of: claude, codex, antigravity
  --all          also install servers whose stdio command does not exist on this
                 machine. By default they are skipped, because a dead server is
                 a startup error in every agent that loads it - and two of the
                 nine here are already dead.
  --force        overwrite whatever already exists on the target. Without it the
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
    --all)   KEEP_DEAD=1; shift ;;
    --agents) ONLY_AGENTS="${2:-}"; [ -n "$ONLY_AGENTS" ] || die "--agents needs a list"; shift 2 ;;
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

  step "What Codex and Antigravity already have"
  # Snapshotted raw, for reference and rollback. The RESTORE does not replay
  # these - it re-derives both from mcp-servers.json, so one edit in Claude Code
  # propagates to all three rather than three files drifting apart.
  for pair in "codex-config.toml:$CODEX_DIR/config.toml" \
              "antigravity-mcp_config.json:$GEMINI_DIR/config/mcp_config.json" \
              "antigravity-config.json:$GEMINI_DIR/config/config.json" \
              "gemini-settings.json:$GEMINI_DIR/settings.json"; do
    dst="${pair%%:*}"; src="${pair#*:}"
    if [ -r "$src" ]; then
      (umask 077 && cp -p "$src" "$DIR/$dst") && ok "$src -> $dst"
    else
      note "$(basename "$src")" "not present"
    fi
  done

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
  info "Restore on the new machine: ./scripts/agents-backup.sh restore -i '$DIR'"
  exit 0
fi

[ -d "$DIR" ] || die "no export directory at $DIR"
[ -r "$DIR/mcp-servers.json" ] || die "$DIR does not look like an agents-backup.sh export"

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
UI_STEPS=6
banner "Agent config restore" "$DIR"

want() { case ",$ONLY_AGENTS," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# A server is "live" if it is HTTP, or stdio whose command actually resolves.
# Writing a dead stdio server into a config is a startup error in every agent
# that reads it - and two of the nine on this machine are already dead.
live_servers() { # -> newline-separated names
  jq -r '.user | to_entries[] | [.key, (.value.type // "stdio"), (.value.command // "")] | @tsv' \
    "$DIR/mcp-servers.json" |
  while IFS=$'\t' read -r name type cmd; do
    if [ "$type" != stdio ] || [ "$KEEP_DEAD" -eq 1 ]; then printf '%s\n' "$name"; continue; fi
    if [ -n "$cmd" ] && { command -v "$cmd" >/dev/null 2>&1 || [ -x "$cmd" ]; }; then
      printf '%s\n' "$name"
    fi
  done
}

step "Preflight"
[ -r "$DIR/mcp-servers.json" ] || die "no mcp-servers.json in $DIR"
jq -e . "$DIR/mcp-servers.json" >/dev/null 2>&1 || die "mcp-servers.json is not valid JSON"
pgrep -x claude >/dev/null 2>&1 &&
  warn "a claude process is running - it may rewrite ~/.claude.json and undo this. Quit it first."
LIVE=$(live_servers)
ALLN=$(jq -r '.user | keys[]' "$DIR/mcp-servers.json")
for n in $ALLN; do
  case $'\n'"$LIVE"$'\n' in *$'\n'"$n"$'\n'*) ;; *) warn "skipping dead server: $n (pass --all to install anyway)" ;; esac
done
ok "$(printf '%s\n' $LIVE | grep -c .) of $(printf '%s\n' $ALLN | grep -c .) servers will be installed into: $ONLY_AGENTS"

# ── skills: one store, symlinks everywhere ───────────────────────────────────
step "Skills -> $AGENTS_DIR/skills"
XOPT="--skip-old-files"; [ "$FORCE" -eq 1 ] && XOPT="--overwrite"
if [ -r "$DIR/agents-skills.tar.gz" ]; then
  mkdir -p "$AGENTS_DIR" &&
  tar xzf "$DIR/agents-skills.tar.gz" -C "$AGENTS_DIR" $XOPT 2>/dev/null &&
    ok "$AGENTS_DIR/skills" || warn "$AGENTS_DIR/skills: extract failed"
fi
if [ -r "$DIR/skills.tar.gz" ]; then
  # Unpack somewhere neutral, then fold every skill into the shared store: the
  # export holds a mix of real directories and relative symlinks, and only the
  # store can be symlinked into three agents at once.
  STAGE=$(mktemp -d) || die "mktemp -d failed"
  tar xzf "$DIR/skills.tar.gz" -C "$STAGE" 2>/dev/null
  mkdir -p "$AGENTS_DIR/skills"
  MOVED=0; LEFT=0
  for f in "$STAGE"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    b=$(basename "$f")
    case "$b" in *.zip) continue ;; esac        # an archive of a skill is not a skill
    # A symlink in the export points into the store, which agents-skills.tar.gz
    # has already restored - nothing to move.
    [ -L "$f" ] && continue
    if [ -e "$AGENTS_DIR/skills/$b" ] && [ "$FORCE" -ne 1 ]; then LEFT=$((LEFT+1)); continue; fi
    rm -rf "$AGENTS_DIR/skills/$b"
    mv "$f" "$AGENTS_DIR/skills/$b" && MOVED=$((MOVED+1))
  done
  rm -rf "$STAGE"
  ok "$MOVED skill(s) folded into the store, $LEFT already there"
fi
SKILL_N=$(find "$AGENTS_DIR/skills" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
ok "$SKILL_N skill(s) in $AGENTS_DIR/skills"

link_skills() { # link_skills <target dir> <relative prefix back to $HOME>
  local dir="$1" up="$2" n=0 skipped=0 repaired=0 b
  mkdir -p "$dir" || { warn "cannot create $dir"; return 1; }
  for src in "$AGENTS_DIR"/skills/*; do
    [ -d "$src" ] || continue
    b=$(basename "$src")
    if [ -L "$dir/$b" ] && [ ! -e "$dir/$b" ]; then
      # A DANGLING link is not "something already there on purpose" - it is the
      # bug this script exists to fix, so it is replaced regardless of --force.
      rm -f "$dir/$b"; repaired=$((repaired+1))
    elif [ -e "$dir/$b" ] || [ -L "$dir/$b" ]; then
      if [ "$FORCE" -eq 1 ]; then rm -rf "$dir/$b"; else skipped=$((skipped+1)); continue; fi
    fi
    # Relative, never absolute. The fourteen skills this machine lost were
    # absolute symlinks to /c/Users/... that stopped resolving the moment the
    # machine changed; a relative link survives any $HOME.
    ln -s "$up/.agents/skills/$b" "$dir/$b" && n=$((n+1))
  done
  note "$dir" "$n linked ($repaired dead link(s) repaired), $skipped left alone"
}

step "Claude Code"
if ! want claude; then
  note "claude" "not in --agents"
elif [ ! -r "$CFG" ]; then
  warn "no $CFG - run 'claude' once so the file exists, then re-run"
else
  BAK="$CFG.bak.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$CFG" "$BAK" && chmod 600 "$BAK" && ok "backed up -> $BAK" || die "could not back up $CFG"
  TMP=$(mktemp) || die "mktemp failed"
  # NB: the config comes in on STDIN. With --args, jq treats every remaining
  # non-option argument as a positional string - including a filename - so
  # `jq --args f 'x' file a b` reads stdin and hangs instead of opening the file.
  if (umask 077 && jq --slurpfile e "$DIR/mcp-servers.json" --argjson force "$FORCE" \
        '($ARGS.positional | map({key: ., value: $e[0].user[.]}) | from_entries) as $new
         | .mcpServers = (if $force == 1 then (.mcpServers // {}) * $new
                                         else $new * (.mcpServers // {}) end)' \
        --args $LIVE < "$CFG" > "$TMP") && jq -e . "$TMP" >/dev/null 2>&1; then
    cat "$TMP" > "$CFG"; chmod 600 "$CFG"; rm -f "$TMP"
    ok "$(printf '%s\n' $LIVE | grep -c .) server(s) merged into ~/.claude.json"
  else
    rm -f "$TMP"; warn "merge produced invalid JSON - $CFG untouched, backup at $BAK"
  fi
  # Project-scope keys are absolute paths; most will not exist here.
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
      else rm -f "$TMP"; warn "$path: merge failed"; fi
    else
      note "$(basename "$path")" "no such directory here - not merged ($names)"
    fi
  done < <(jq -r '.projects | to_entries[] | [.key, (.value | keys | join(", "))] | @tsv' "$DIR/mcp-servers.json")

  if [ -r "$DIR/config.tar.gz" ]; then
    mkdir -p "$CLAUDE_DIR" &&
    tar xzf "$DIR/config.tar.gz" -C "$CLAUDE_DIR" $XOPT 2>/dev/null &&
      ok "settings, rules and plugin lists" || warn "config.tar.gz: extract failed"
    if [ -r "$CLAUDE_DIR/plugins/installed_plugins.json" ]; then
      info "Plugins are NOT restored. Reinstall these with /plugin install <name>:"
      jq -r '.plugins // {} | keys[]' "$CLAUDE_DIR/plugins/installed_plugins.json" 2>/dev/null |
        sed 's/^/      /'
    fi
  fi
  link_skills "$CLAUDE_DIR/skills" "../.."
fi

step "Codex"
if ! want codex; then
  note "codex" "not in --agents"
else
  # TOML, not JSON - and rather than parse arbitrary TOML with a dependency this
  # repo does not have, the servers go in a MARKED BLOCK that is rewritten whole
  # on every run. Idempotent, and it never touches a line you wrote yourself.
  #
  # NB: Codex picks the transport from the KEYS, not a `type` field - `url` means
  # streamable HTTP, `command` means stdio. Headers are `http_headers`, and a
  # second `[mcp_servers.X]` table for a server you already defined by hand would
  # be a duplicate-key parse error, so those are detected and skipped.
  CT="$CODEX_DIR/config.toml"
  mkdir -p "$CODEX_DIR"
  [ -e "$CT" ] || : > "$CT"
  BEGIN='# >>> agents-backup.sh managed block >>>'
  END='# <<< agents-backup.sh managed block <<<'
  STRIP=$(mktemp)
  awk -v b="$BEGIN" -v e="$END" '$0==b{skip=1} !skip{print} $0==e{skip=0}' "$CT" > "$STRIP"
  # Names the user defined outside our block, which we must not redefine.
  MINE=$(grep -oE '^\[mcp_servers\.[^]]+\]' "$STRIP" 2>/dev/null |
         sed -E 's/^\[mcp_servers\.//; s/\]$//; s/^"//; s/".*$//; s/\..*$//' | sort -u)
  BLOCK=$(mktemp); WROTE=0
  { printf '%s\n' "$BEGIN"
    printf '# Written by scripts/agents-backup.sh. Edits inside this block are lost\n'
    printf '# on the next restore; put your own servers outside it.\n'
    for n in $LIVE; do
      case $'\n'"$MINE"$'\n' in *$'\n'"$n"$'\n'*)
        warn "codex: [mcp_servers.$n] already defined by hand - left alone"; continue ;; esac
      jq -r --arg n "$n" '
        .user[$n] as $s
        | "", "[mcp_servers." + ($n|@json) + "]",
          (if $s.command then "command = " + ($s.command|@json) else empty end),
          (if ($s.args // []) | length > 0
             then "args = [" + ([$s.args[] | @json] | join(", ")) + "]" else empty end),
          (if $s.url then "url = " + ($s.url|@json) else empty end),
          (if ($s.env // {}) | length > 0
             then "", "[mcp_servers." + ($n|@json) + ".env]",
                  ($s.env | to_entries[] | (.key|@json) + " = " + (.value|@json))
             else empty end),
          (if ($s.headers // {}) | length > 0
             then "", "[mcp_servers." + ($n|@json) + ".http_headers]",
                  ($s.headers | to_entries[] | (.key|@json) + " = " + (.value|@json))
             else empty end)' "$DIR/mcp-servers.json"
      WROTE=$((WROTE+1))
    done
    printf '%s\n' "$END"
  } > "$BLOCK"
  if (umask 077 && cat "$STRIP" "$BLOCK" > "$CT.new") && [ -s "$CT.new" ]; then
    [ -s "$CT" ] && cp -p "$CT" "$CT.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    mv "$CT.new" "$CT" && chmod 600 "$CT" && ok "$CT  ($WROTE server(s) in the managed block)"
  else
    rm -f "$CT.new"; warn "could not write $CT"
  fi
  rm -f "$STRIP" "$BLOCK"
  link_skills "$CODEX_DIR/skills" "../.."
fi

step "Antigravity"
if ! want antigravity; then
  note "antigravity" "not in --agents"
else
  # Antigravity reads the same {"mcpServers": {...}} shape Claude Code uses, so
  # this is a merge, not a translation. Evidence for the path: on this machine
  # ~/.gemini/config/mcp_config.json holds all eight servers AND
  # ~/.gemini/antigravity/mcp/ has a per-server cache directory for exactly the
  # six of them that are live.
  AG="$GEMINI_DIR/config/mcp_config.json"
  mkdir -p "$(dirname "$AG")"
  [ -e "$AG" ] || echo '{"mcpServers":{}}' > "$AG"
  TMP=$(mktemp)
  if (umask 077 && jq --slurpfile e "$DIR/mcp-servers.json" --argjson force "$FORCE" \
        '($ARGS.positional | map({key: ., value: $e[0].user[.]}) | from_entries) as $new
         | .mcpServers = (if $force == 1 then ((.mcpServers // {}) * $new)
                                         else ($new * (.mcpServers // {})) end)' \
        --args $LIVE < "$AG" > "$TMP") && jq -e . "$TMP" >/dev/null 2>&1; then
    [ -s "$AG" ] && cp -p "$AG" "$AG.bak.$(date -u +%Y%m%dT%H%M%SZ)"
    cat "$TMP" > "$AG"; chmod 600 "$AG"; rm -f "$TMP"
    ok "$AG  ($(jq '.mcpServers | length' "$AG") server(s))"
  else
    rm -f "$TMP"; warn "could not merge $AG"
  fi
  # ~/.gemini/config/skills is Antigravity 2.0's global skills directory. Not a
  # guess from the docs, which disagree with each other - it is on this machine,
  # and it already mirrors ~/.claude/skills entry for entry.
  #
  # NB - AND EVERY LINK IN IT IS CURRENTLY DEAD. Measured 2026-09-04: 27 of 27.
  # Whatever populated it copied Claude Code's link text verbatim without
  # adjusting for the extra directory level, so `../../.agents/skills/X` resolves
  # to ~/.gemini/.agents/... instead of ~/.agents/... . Antigravity can therefore
  # see only the three skills that happen to be real directories. The depth here
  # is ../../.. for exactly that reason, and link_skills repairs dangling links
  # without needing --force.
  link_skills "$GEMINI_DIR/config/skills" "../../.."
fi

steps_end
rule
info "Verify:  claude mcp list  ·  codex mcp list  ·  Antigravity > Settings > MCP servers"
info "Skills live in $AGENTS_DIR/skills; every agent symlinks to them."
