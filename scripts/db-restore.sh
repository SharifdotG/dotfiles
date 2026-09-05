#!/usr/bin/env bash
# Restore a snapshot written by scripts/db-backup.sh onto a fresh machine.
# This is the "yet another script" half: clone the repo, bring nothing up by
# hand, point this at the snapshot directory.
#
# ORDER IS THE CONTENT, the same way MIGRATION.md Stage 5 is:
#
#   1. .env files   - compose cannot even start without them, and a git clone
#                     will never bring them back
#   2. volumes      - MinIO and the small state volumes, extracted while nothing
#                     is mounted on them
#   3. the stack    - `docker compose up -d <db service>`, one service, not all
#   4. pg_restore   - into the running container, so client and server versions
#                     always match
#
# THIS IS DESTRUCTIVE. pg_restore --clean drops every object it is about to
# recreate. It prompts once per database unless you pass --yes.
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

SNAP=""; ONLY=""; ASSUME_YES=0; DO_GLOBALS=0; LIST_ONLY=0

# ── where projects live NOW ──────────────────────────────────────────────────
# A snapshot records each project's directory as the ABSOLUTE path it had at
# backup time, read from docker's com.docker.compose.project.working_dir label.
# That is historical fact and must not be rewritten - the snapshot is evidence.
# But it goes stale the moment a project tree moves, and then every path in
# every existing snapshot is wrong at once.
#
# Observed 2026-09-06: the code tree moved from ~/Documents/Code/VSCode to
# ~/Documents/Code, one path segment shallower, and a restore of a snapshot
# taken two days earlier skipped EVERYTHING - 0 of 2 databases, 0 of 3 .env
# files - reporting only "project directory not found". Nothing was wrong with
# the snapshot; every project was on disk, one directory over.
#
# So the recorded path is a starting point, not an answer. resolve_wd() below
# takes the recorded path and finds where that project actually is now.
CODE_ROOT="${CODE_ROOT:-$HOME/Documents/Code}"
REMAPS=()

usage() {
  cat <<'EOS'
usage: scripts/db-restore.sh <snapshot-dir> [--only PROJECT] [--globals] [--yes]
       scripts/db-restore.sh <snapshot-dir> --list

  <snapshot-dir>   a timestamped directory written by scripts/db-backup.sh
  --only PROJECT   restore one compose project only (e.g. structflow, tryton)
  --globals        also apply the pg_dumpall --globals-only role dump. Normally
                   you do NOT want this: the compose entrypoint creates the role
                   on a fresh volume, and the dump's roles collide with it.
                   Use it when a database depends on roles the entrypoint does
                   not create.
  --yes            do not prompt before each destructive restore
  --list           print what the snapshot contains and exit, touching nothing
  --code-root DIR  where project trees live now (default ~/Documents/Code, or
                   $CODE_ROOT). A snapshot stores the absolute path each
                   project had when it was taken; if the tree has moved since,
                   this is the root the relocation search starts from.
  --remap OLD=NEW  rewrite a recorded path prefix explicitly. Repeatable. Only
                   needed when the automatic search guesses wrong or when a
                   project moved somewhere outside --code-root, e.g.
                     --remap "$HOME/Documents/Code/VSCode=$HOME/Documents/Code"
EOS
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="${2:-}"; [ -n "$ONLY" ] || die "--only needs a project name"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --globals) DO_GLOBALS=1; shift ;;
    --list)    LIST_ONLY=1; shift ;;
    --code-root) CODE_ROOT="${2:-}"; [ -n "$CODE_ROOT" ] || die "--code-root needs a directory"
               [ -d "$CODE_ROOT" ] || die "--code-root: no such directory: $CODE_ROOT"; shift 2 ;;
    --remap)   [ -n "${2:-}" ] || die "--remap needs OLD=NEW"
               case "$2" in *=*) ;; *) die "--remap wants OLD=NEW, got: $2" ;; esac
               REMAPS+=("$2"); shift 2 ;;
    -h|--help) usage 0 ;;
    -*)        warn "unknown argument: $1"; usage 1 ;;
    *)         [ -z "$SNAP" ] || { warn "more than one snapshot directory given"; usage 1; }
               SNAP="$1"; shift ;;
  esac
done

[ -n "$SNAP" ] || usage 1
[ -d "$SNAP" ] || die "no such directory: $SNAP"

# ── finding a project that has moved since the snapshot ──────────────────────
# A compose file is the tell that a directory really is the project root, and
# not merely a directory with the right name. All four spellings are in use
# across these repos - structflow has docker-compose.yml, tryton has
# compose.yml, integration-layer-api has docker-compose.yaml - so check all of
# them rather than assuming one.
_compose_in() { # _compose_in <dir>
  [ -f "$1/docker-compose.yml"  ] || [ -f "$1/docker-compose.yaml" ] ||
  [ -f "$1/compose.yml"         ] || [ -f "$1/compose.yaml"        ]
}

# resolve_wd <recorded path> -> prints a usable directory, or nothing (exit 1).
# Three strategies, most trustworthy first.
resolve_wd() {
  local wd="$1" rel cand best="" m old new
  [ -n "$wd" ] && [ "$wd" != "-" ] || return 1

  # 1. The recorded path still exists. Nothing has moved; use it verbatim.
  [ -d "$wd" ] && { printf '%s' "$wd"; return 0; }

  # 2. An explicit --remap the caller supplied, tried in the order given. This
  #    outranks the search below on purpose: an operator saying where something
  #    went is better evidence than anything this script can infer.
  for m in ${REMAPS[@]+"${REMAPS[@]}"}; do
    old="${m%%=*}"; new="${m#*=}"
    case "$wd" in
      "$old"*) cand="$new${wd#"$old"}"
               [ -d "$cand" ] && { printf '%s' "$cand"; return 0; } ;;
    esac
  done

  # 3. Search under CODE_ROOT for the LONGEST trailing part of the recorded
  #    path that exists there. Longest first is what keeps this honest:
  #
  #      recorded  /home/me/Documents/Code/VSCode/SocialHousingOSS/tryton
  #      tries     $CODE_ROOT/home/me/Documents/Code/VSCode/SocialHousingOSS/tryton
  #                $CODE_ROOT/me/Documents/...
  #                ...
  #                $CODE_ROOT/SocialHousingOSS/tryton     <- hit, and specific
  #                $CODE_ROOT/tryton                      <- never reached
  #
  #    Taking the shortest match instead would happily bind a project called
  #    `tryton` sitting anywhere in the tree. A directory that also holds a
  #    compose file wins outright; a bare directory is remembered as a fallback
  #    but the search continues, because "named right AND has a compose file"
  #    beats "named right" at any depth.
  rel="${wd#/}"
  while [ -n "$rel" ]; do
    cand="$CODE_ROOT/$rel"
    if [ -d "$cand" ]; then
      _compose_in "$cand" && { printf '%s' "$cand"; return 0; }
      [ -n "$best" ] || best="$cand"
    fi
    case "$rel" in */*) rel="${rel#*/}" ;; *) rel="" ;; esac
  done

  [ -n "$best" ] && { printf '%s' "$best"; return 0; }
  return 1
}

# Say it once, loudly, rather than per row - a relocation is a thing the
# operator must be able to see and disagree with, not a silent correction.
_RELOC_SAID=""
say_reloc() { # say_reloc <project> <recorded> <resolved>
  [ "$2" = "$3" ] && return 0
  case "$_RELOC_SAID" in *"|$1|"*) return 0 ;; esac
  _RELOC_SAID="$_RELOC_SAID|$1|"
  note "$1 moved" "$2 -> $3"
}
MAN_DB="$SNAP/databases.tsv"; MAN_VOL="$SNAP/volumes.tsv"
[ -r "$MAN_DB" ] || die "$SNAP does not look like a db-backup.sh snapshot (no databases.tsv)"

# ── --list: read-only, and worth running first every single time ─────────────
if [ "$LIST_ONLY" -eq 1 ]; then
  banner "Snapshot contents" "$SNAP"
  [ -r "$SNAP/manifest.txt" ] && sed 's/^/  /' "$SNAP/manifest.txt"
  rule
  info "Databases"
  awk -F'\t' '!/^#/ && NF { printf "    %-14s %-12s %-22s %s\n", $1, $5, $4, $7 }' "$MAN_DB"
  if [ -r "$MAN_VOL" ]; then
    info "Volumes"
    awk -F'\t' '!/^#/ && NF { printf "    %-42s %s\n", $1, $2 }' "$MAN_VOL"
  fi
  exit 0
fi

UI_STEPS=5
banner "Database restore" "$SNAP"

command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running? are you in the docker group?)"

confirm() { # confirm <question>
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local a; read -r -p "  $1 [y/N] " a
  case "${a:-n}" in [yY]*) return 0 ;; *) return 1 ;; esac
}
crunning() { [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null)" = true ]; }
cexists()  { docker inspect "$1" >/dev/null 2>&1; }
wait_ready() { # wait_ready <container> <user> <db>
  # NB: THE CHECK IS OVER TCP, AND THAT IS THE WHOLE POINT. When the official
  # postgres image initialises an empty volume it first brings up a TEMPORARY
  # server bound to the unix socket ONLY, runs the init scripts against it, then
  # shuts it down and starts the real one. A socket-based `pg_isready` says
  # "ready" to that temporary server - so a restore started on its word dies
  # partway through with "FATAL: the database system is shutting down", having
  # already loaded some of the data. Binding-to-socket-only is exactly how the
  # image marks the init phase, so asking over 127.0.0.1 is what skips it.
  local i
  for i in $(seq 1 120); do
    docker exec "$1" pg_isready -h 127.0.0.1 -U "$2" -d "$3" >/dev/null 2>&1 && return 0
    sleep 0.5
  done
  # A server that genuinely does not listen on TCP is unusual but legal. Accept
  # it rather than failing the backup outright - by now the init phase, if there
  # was one, is long over.
  if docker exec "$1" pg_isready -U "$2" -d "$3" >/dev/null 2>&1; then
    warn "$1: ready on the unix socket but not on TCP - continuing"
    return 0
  fi
  return 1
}

# ── 1. integrity, before anything is changed ─────────────────────────────────
step "Verifying the snapshot"
BAD=0
while IFS=$'\t' read -r _p _s _c _i _db _u file _bytes sum _wd; do
  case "$_p" in '#'*|'') continue ;; esac
  [ -r "$SNAP/$file" ] || { warn "missing: $file"; BAD=$((BAD+1)); continue; }
  [ "$(sha256sum "$SNAP/$file" | cut -d' ' -f1)" = "$sum" ] ||
    { warn "checksum mismatch: $file"; BAD=$((BAD+1)); }
done < "$MAN_DB"
if [ -r "$MAN_VOL" ]; then
  while IFS=$'\t' read -r vol file _bytes sum; do
    case "$vol" in '#'*|'') continue ;; esac
    [ -r "$SNAP/$file" ] || { warn "missing: $file"; BAD=$((BAD+1)); continue; }
    [ "$(sha256sum "$SNAP/$file" | cut -d' ' -f1)" = "$sum" ] ||
      { warn "checksum mismatch: $file"; BAD=$((BAD+1)); }
  done < "$MAN_VOL"
fi
[ "$BAD" -eq 0 ] || die "$BAD damaged or missing artifact(s) - stopping before anything is written"
ok "every artifact present and checksums match"

# ── 2. the .env files ────────────────────────────────────────────────────────
# Never overwritten. A .env that already exists on the new machine is the one
# you meant to keep; this snapshot's copy is by definition older.
step "Project .env files"
if [ ! -d "$SNAP/env" ]; then
  warn "no env/ in the snapshot (--no-env was used) - supply the passwords yourself"
else
  PLACED=0; SKIPPED=0
  while IFS= read -r src; do
    rel="${src#"$SNAP"/env/}"; proj="${rel%%/*}"; sub="${rel#*/}"
    [ -z "$ONLY" ] || [ "$proj" = "$ONLY" ] || continue
    # Where did this project live? Take it from the manifest, fall back to the
    # same path the old machine used (MIGRATION.md keeps the username identical).
    wd=$(awk -F'\t' -v p="$proj" '!/^#/ && $1 == p && $10 != "-" { print $10; exit }' "$MAN_DB")
    [ -n "$wd" ] || wd=$(awk -F'\t' -v p="$proj" '$1 == p { print $2; exit }' <(
      sed -n '/compose projects/,/^$/p' "$SNAP/manifest.txt" 2>/dev/null | sed 's/^  //'))
    # The recorded path is where this project lived when the snapshot was taken.
    # resolve_wd finds where it is now; only a genuinely absent project falls
    # through to the warning.
    rec="$wd"; wd=$(resolve_wd "$rec") || wd=""
    if [ -z "$wd" ]; then
      warn "$proj: project directory not found - clone it first, then re-run"
      note "  looked for" "${rec:-<nothing recorded>}, then under $CODE_ROOT"
      SKIPPED=$((SKIPPED+1)); continue
    fi
    say_reloc "$proj" "$rec" "$wd"
    dst="$wd/$sub"
    if [ -e "$dst" ]; then
      note "$proj/$sub" "already present, left alone"; SKIPPED=$((SKIPPED+1)); continue
    fi
    mkdir -p "$(dirname "$dst")" && cp -p "$src" "$dst" &&
      { ok "$proj/$sub -> $dst"; PLACED=$((PLACED+1)); } ||
      { warn "$proj/$sub: copy failed"; SKIPPED=$((SKIPPED+1)); }
  done < <(find "$SNAP/env" -type f 2>/dev/null)
  ok "$PLACED placed, $SKIPPED skipped"
fi

# ── 3. volumes ───────────────────────────────────────────────────────────────
step "Volumes"
if [ ! -r "$MAN_VOL" ]; then
  ok "none in this snapshot"
else
  while IFS=$'\t' read -r vol file _bytes _sum; do
    case "$vol" in '#'*|'') continue ;; esac
    [ -z "$ONLY" ] || case "$vol" in "$ONLY"_*|"$ONLY"-*) ;; *) continue ;; esac

    users=()
    while read -r c; do [ -n "$c" ] && crunning "$c" && users+=("$c"); done \
      < <(docker ps -a -q --filter "volume=$vol")
    if [ "${#users[@]}" -gt 0 ]; then
      confirm "$vol is mounted by ${#users[@]} running container(s). Stop them and overwrite?" ||
        { note "$vol" "skipped"; continue; }
      docker stop ${users+"${users[@]}"} >/dev/null 2>&1
    elif ! confirm "Overwrite volume $vol from the snapshot?"; then
      note "$vol" "skipped"; continue
    fi

    docker volume create "$vol" >/dev/null 2>&1
    # Empty the volume first: tar x merges, so a stale file that is not in the
    # tarball would survive the "restore" and look like live data.
    if docker run --rm -v "$vol":/data -v "$SNAP/volumes":/backup:ro alpine sh -c \
         'rm -rf /data/..?* /data/.[!.]* /data/* 2>/dev/null; tar xzf "/backup/$1" -C /data' \
         _ "$(basename "$file")" >/dev/null 2>&1; then
      ok "$vol restored"
    else
      warn "$vol: extract failed"
    fi
    [ "${#users[@]}" -gt 0 ] && docker start ${users+"${users[@]}"} >/dev/null 2>&1
  done < "$MAN_VOL"
fi

# ── 4 & 5. bring each database service up, then load it ──────────────────────
step "Databases"
DONE=0; TOTAL=0
while IFS=$'\t' read -r proj svc cont image db user file _bytes _sum wd; do
  case "$proj" in '#'*|'') continue ;; esac
  [ -z "$ONLY" ] || [ "$proj" = "$ONLY" ] || continue
  TOTAL=$((TOTAL+1))
  info "$proj / $db  ($image)"

  # Get a server running. Prefer the container that already exists; otherwise
  # ask compose for exactly one service, not the whole stack - the app must not
  # come up and start writing before its data is in.
  # Same relocation as the .env step: $wd is the path the snapshot recorded,
  # which is stale as soon as the code tree moves.
  rec="$wd"; wd=$(resolve_wd "$rec") || wd=""
  [ -n "$wd" ] && say_reloc "$proj" "$rec" "$wd"

  if cexists "$cont"; then
    crunning "$cont" || docker start "$cont" >/dev/null 2>&1
  elif [ -n "$wd" ]; then
    ( cd "$wd" && docker compose up -d "$svc" ) >/dev/null 2>&1 ||
      { warn "$proj: 'docker compose up -d $svc' failed in $wd"; continue; }
    cont=$(docker ps -q --filter "label=com.docker.compose.project=$proj" \
                       --filter "label=com.docker.compose.service=$svc" | head -1)
    [ -n "$cont" ] || { warn "$proj: compose started nothing named $svc"; continue; }
  else
    warn "$proj: no container '$cont' and no project directory"
    note "  looked for" "${rec:-<nothing recorded>}, then under $CODE_ROOT"
    warn "  clone the repo, or bring the stack up yourself, then re-run with --only $proj"
    continue
  fi

  wait_ready "$cont" "$user" "$db" ||
    { warn "$proj: $db never became ready"; continue; }

  pass=$(docker inspect "$cont" --format '{{range .Config.Env}}{{println .}}{{end}}' |
         sed -n 's/^POSTGRES_PASSWORD=//p' | head -1)

  confirm "Restore into $db? pg_restore --clean DROPS existing objects first." ||
    { note "$proj/$db" "skipped"; continue; }

  if [ "$DO_GLOBALS" -eq 1 ] && [ -r "$SNAP/${file%.dump}.globals.sql" ]; then
    docker exec -i -e PGPASSWORD="$pass" "$cont" psql -U "$user" -d postgres \
      >/dev/null 2>&1 < "$SNAP/${file%.dump}.globals.sql" &&
      ok "globals applied" || warn "globals failed (usually harmless - the role already exists)"
  fi

  err=$(mktemp)
  docker exec -i -e PGPASSWORD="$pass" "$cont" \
    pg_restore -U "$user" -d "$db" --clean --if-exists --no-owner --no-privileges \
    < "$SNAP/$file" 2>"$err"
  rc=$?
  # pg_restore exits 1 when it ignored errors and still finished. That is not the
  # same as a failed restore, and it is not the same as a clean one either - say
  # which, rather than printing a green tick over a partial load.
  if [ "$rc" -eq 0 ]; then
    ok "$proj/$db restored clean"
    DONE=$((DONE+1))
  elif [ -s "$err" ] && grep -q 'errors ignored on restore' "$err"; then
    warn "$proj/$db restored WITH ERRORS - read them before trusting this database:"
    sed 's/^/      /' "$err" >&2
    DONE=$((DONE+1))
  else
    warn "$proj/$db FAILED (exit $rc)"; sed 's/^/      /' "$err" >&2
  fi
  rm -f "$err"
done < "$MAN_DB"

steps_end
rule
bar "$DONE" "$TOTAL" "databases restored"
info "Now bring the rest of each stack up:  cd <project> && docker compose up -d"
