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
EOS
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --only)    ONLY="${2:-}"; [ -n "$ONLY" ] || die "--only needs a project name"; shift 2 ;;
    --yes|-y)  ASSUME_YES=1; shift ;;
    --globals) DO_GLOBALS=1; shift ;;
    --list)    LIST_ONLY=1; shift ;;
    -h|--help) usage 0 ;;
    -*)        warn "unknown argument: $1"; usage 1 ;;
    *)         [ -z "$SNAP" ] || { warn "more than one snapshot directory given"; usage 1; }
               SNAP="$1"; shift ;;
  esac
done

[ -n "$SNAP" ] || usage 1
[ -d "$SNAP" ] || die "no such directory: $SNAP"
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
    if [ -z "$wd" ] || [ ! -d "$wd" ]; then
      warn "$proj: project directory not found - clone it first, then re-run"
      SKIPPED=$((SKIPPED+1)); continue
    fi
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
  if cexists "$cont"; then
    crunning "$cont" || docker start "$cont" >/dev/null 2>&1
  elif [ "$wd" != "-" ] && [ -d "$wd" ]; then
    ( cd "$wd" && docker compose up -d "$svc" ) >/dev/null 2>&1 ||
      { warn "$proj: 'docker compose up -d $svc' failed in $wd"; continue; }
    cont=$(docker ps -q --filter "label=com.docker.compose.project=$proj" \
                       --filter "label=com.docker.compose.service=$svc" | head -1)
    [ -n "$cont" ] || { warn "$proj: compose started nothing named $svc"; continue; }
  else
    warn "$proj: no container '$cont' and no project directory at '$wd'"
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
