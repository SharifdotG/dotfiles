#!/usr/bin/env bash
# Dump every Dockerised database on this machine into one restorable directory.
# Pairs with scripts/db-restore.sh. Run it on the OLD machine, before the wipe.
#
# WHY LOGICAL DUMPS AND NOT JUST VOLUME TARBALLS. docs/MIGRATION.md Stage 3 tars
# the named volumes, and for MinIO and the small state volumes that is right. For
# Postgres it is not, for two independent reasons:
#
#   1. A tar of a LIVE PGDATA is a torn snapshot. It restores cleanly, passes a
#      smoke test, and corrupts at the first checkpoint.
#   2. A PGDATA directory is bound to its major version. This machine runs
#      postgres 15, 16 and 17 side by side; a 15 volume will not start under 17,
#      and there is no in-place path across a reinstall.
#
# `pg_dump -Fc` has neither problem, so the split is by rule:
#
#   Postgres data volume  -> pg_dump -Fc, run INSIDE the container so the dump
#                            client version always matches the server it dumps
#   every other volume    -> tar, with the containers that mount it STOPPED
#
# THE OUTPUT DIRECTORY CONTAINS SECRETS - the projects' .env files, and role
# password hashes in the globals dump. It is created 0700. Never put it in a repo
# and never put it only on the external drive (see MIGRATION.md Stage 3).
set -uo pipefail
cd "$(dirname "$0")/.."
. lib/log.sh

OUT_ROOT="${DB_BACKUP_DIR:-$HOME/Backup/db}"
STOP_FOR_TAR=1
COPY_ENV=1

usage() {
  cat <<'EOS'
usage: scripts/db-backup.sh [-o DIR] [--live] [--no-env]

  -o, --out DIR   parent directory for the snapshot   (default ~/Backup/db,
                  or $DB_BACKUP_DIR). A timestamped subdirectory is created.
      --live      do NOT stop containers while tarring their volumes. Faster,
                  and wrong for anything that buffers writes. Postgres is never
                  tarred either way, so this is only about MinIO and friends.
      --no-env    do not copy the compose projects' .env files into the snapshot.
                  The snapshot then holds no secrets - and cannot be restored
                  without you supplying the same passwords by hand.
EOS
  exit "${1:-0}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    -o|--out) OUT_ROOT="${2:-}"; [ -n "$OUT_ROOT" ] || die "--out needs a directory"; shift 2 ;;
    --live)   STOP_FOR_TAR=0; shift ;;
    --no-env) COPY_ENV=0; shift ;;
    -h|--help) usage 0 ;;
    *) warn "unknown argument: $1"; usage 1 ;;
  esac
done

UI_STEPS=6
banner "Database backup" "logical dumps for Postgres, tarballs for the rest"

# ── helpers ──────────────────────────────────────────────────────────────────
# Read one variable out of a container's baked-in environment. Works on stopped
# containers, which is the point - most of these are not running.
cenv() { # cenv <container> <VAR>
  docker inspect "$1" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null |
    sed -n "s/^$2=//p" | head -1
}
clabel() { docker inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null; }
crunning() { [ "$(docker inspect "$1" --format '{{.State.Running}}' 2>/dev/null)" = true ]; }
slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'; }

# Throwaway containers we spun up to read a stopped database's volume.
SCRATCH=()
cleanup() {
  local c
  for c in ${SCRATCH+"${SCRATCH[@]}"}; do docker rm -f "$c" >/dev/null 2>&1; done
  _ui_show_cursor 2>/dev/null || true
}
trap cleanup EXIT INT TERM

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

# ── 1. preflight ─────────────────────────────────────────────────────────────
step "Preflight"
command -v docker >/dev/null || die "docker is not installed"
docker info >/dev/null 2>&1 || die "cannot talk to the docker daemon (is it running? are you in the docker group?)"
ok "docker daemon reachable"

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT="$OUT_ROOT/$STAMP"
(umask 077 && mkdir -p "$OUT/pg" "$OUT/volumes" "$OUT/env") || die "cannot create $OUT"
chmod 700 "$OUT_ROOT" "$OUT" 2>/dev/null
ok "snapshot directory $OUT"

MAN_DB="$OUT/databases.tsv"
MAN_VOL="$OUT/volumes.tsv"
printf '# project\tservice\tcontainer\timage\tdb\tuser\tfile\tbytes\tsha256\tworkdir\n' > "$MAN_DB"
printf '# volume\tfile\tbytes\tsha256\n' > "$MAN_VOL"

# ── 2. find the Postgres containers ──────────────────────────────────────────
step "Discovering Postgres containers"
PG=()
while read -r id img; do
  case "$img" in *postgres:*|*postgres) PG+=("$id") ;; esac
done < <(docker ps -a --format '{{.ID}} {{.Image}}')
PG_N=${#PG[@]}
[ "$PG_N" -gt 0 ] || warn "no Postgres containers found - nothing to dump"
for id in ${PG+"${PG[@]}"}; do
  note "$(docker inspect "$id" --format '{{.Name}}' | sed 's|^/||')" \
       "$(docker inspect "$id" --format '{{.Config.Image}}')$(crunning "$id" || echo '  (stopped)')"
done

# ── 3. dump them ─────────────────────────────────────────────────────────────
step "pg_dump"
PG_OK=0
PG_COVERED_VOLUMES=" "
for id in ${PG+"${PG[@]}"}; do
  name=$(docker inspect "$id" --format '{{.Name}}' | sed 's|^/||')
  image=$(docker inspect "$id" --format '{{.Config.Image}}')
  proj=$(clabel "$id" com.docker.compose.project); [ -n "$proj" ] || proj="$name"
  svc=$(clabel "$id" com.docker.compose.service);  [ -n "$svc" ]  || svc="-"
  wd=$(clabel "$id" com.docker.compose.project.working_dir); [ -n "$wd" ] || wd="-"
  user=$(cenv "$id" POSTGRES_USER); [ -n "$user" ] || user=postgres
  db=$(cenv "$id" POSTGRES_DB);     [ -n "$db" ]   || db="$user"

  # Which named volume holds this cluster, and where it is mounted.
  pgvol=""; pgdest=""
  while read -r vol dest; do
    [ -n "$vol" ] || continue
    case "$dest" in */postgresql/data*|*/pgdata*) pgvol="$vol"; pgdest="$dest"; break ;; esac
  done < <(docker inspect "$id" --format '{{range .Mounts}}{{.Name}} {{.Destination}}
{{end}}')

  # A RUNNING container is dumped in place. A STOPPED one is read through a
  # throwaway container built from the SAME IMAGE on the SAME VOLUME.
  #
  # NB: this is not a stylistic choice. `docker start` on the real container
  # republishes its host ports, and on this machine structflow's and tryton's
  # Postgres both claim 5432 - so starting the stopped one fails whenever the
  # other is up, which is most of the time. The throwaway publishes nothing, so
  # it cannot collide, it works even if the container has been deleted, and it
  # never leaves the user's stack in a state this script chose for it.
  #
  # NB: the throwaway is given NO POSTGRES_PASSWORD deliberately. If the volume
  # turned out to be empty, the official entrypoint would refuse to initialise
  # without one and fail loudly - rather than quietly creating a fresh empty
  # cluster and handing us a dump that restores perfectly and contains nothing.
  scratch=""
  if crunning "$id"; then
    target="$id"
  elif [ -n "$pgvol" ]; then
    busy=$(docker ps -q --filter "volume=$pgvol" | head -1)
    if [ -n "$busy" ]; then
      warn "$name: stopped, but $pgvol is mounted by a running container - SKIPPED"; continue
    fi
    pgdata=$(cenv "$id" PGDATA)
    scratch=$(docker run -d --rm -v "$pgvol":"$pgdest" \
                ${pgdata:+-e PGDATA="$pgdata"} "$image" 2>&1)
    if ! docker inspect "$scratch" >/dev/null 2>&1; then
      warn "$name: could not open $pgvol with $image - SKIPPED"
      printf '      %s\n' "$scratch" >&2; continue
    fi
    SCRATCH+=("$scratch"); target="$scratch"
    note "$name" "stopped - reading $pgvol through a throwaway $image"
  else
    warn "$name: stopped and has no named data volume - SKIPPED"; continue
  fi

  if ! wait_ready "$target" "$user" "$db"; then
    warn "$name: never became ready - SKIPPED"
    [ -n "$scratch" ] && { docker logs --tail 5 "$scratch" 2>&1 | sed 's/^/      /' >&2; \
                           docker rm -f "$scratch" >/dev/null 2>&1; }
    continue
  fi

  base="$(slug "$proj")__$(slug "$db")"
  f="$OUT/pg/$base.dump"
  g="$OUT/pg/$base.globals.sql"

  # -Fc: the custom format, the only one pg_restore can be selective about.
  # No -t/-T/-n: a partial dump is the kind of backup that is discovered to be
  # partial on the day it is needed.
  if ! docker exec "$target" \
       pg_dump -U "$user" -d "$db" -Fc -Z6 --no-owner --no-privileges > "$f" 2>"$f.err"; then
    warn "$name: pg_dump failed"; sed 's/^/      /' "$f.err" >&2; rm -f "$f" "$f.err"
    [ -n "$scratch" ] && docker rm -f "$scratch" >/dev/null 2>&1
    continue
  fi
  rm -f "$f.err"

  # An empty or truncated dump is the classic silent failure: the redirect
  # created the file before the command failed, so the file exists and is wrong.
  # pg_restore -l parses the archive's table of contents - it is the cheapest
  # real proof that what landed on disk is a readable dump and not a fragment.
  if ! docker exec -i "$target" pg_restore -l >/dev/null 2>&1 < "$f"; then
    warn "$name: dump is not a readable pg archive - DISCARDED"; rm -f "$f"
    [ -n "$scratch" ] && docker rm -f "$scratch" >/dev/null 2>&1
    continue
  fi

  # Roles live outside any one database, so they are not in the dump above.
  # Kept for reference; db-restore.sh does NOT apply them unless asked, because
  # the compose entrypoint creates the role itself on a fresh volume.
  docker exec "$target" pg_dumpall -U "$user" --globals-only > "$g" 2>/dev/null || rm -f "$g"

  bytes=$(stat -c%s "$f"); sum=$(sha256sum "$f" | cut -d' ' -f1)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$proj" "$svc" "$name" "$image" "$db" "$user" "pg/$base.dump" "$bytes" "$sum" "$wd" >> "$MAN_DB"
  ok "$proj/$db  $(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")  ($image)"
  PG_OK=$((PG_OK + 1))

  # Only NOW is the volume covered. Marking it before the dump would mean a
  # failed dump silently loses the tarball fallback too - the one case where
  # both halves of this script would have skipped the same data.
  [ -n "$pgvol" ] && PG_COVERED_VOLUMES="$PG_COVERED_VOLUMES$pgvol "
  [ -n "$scratch" ] && docker rm -f "$scratch" >/dev/null 2>&1
done

# ── 4. tar every other named volume ──────────────────────────────────────────
step "Volume tarballs"
VOL_OK=0; VOL_N=0
while read -r vol; do
  [ -n "$vol" ] || continue
  # Anonymous volumes: a 64-hex name docker generated for an unnamed mount.
  # They hold nothing a rebuild will not recreate.
  case "$vol" in
    [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*)
      [ "${#vol}" -eq 64 ] && continue ;;
  esac
  case "$PG_COVERED_VOLUMES" in *" $vol "*) continue ;; esac
  VOL_N=$((VOL_N + 1))

  users=(); 
  if [ "$STOP_FOR_TAR" -eq 1 ]; then
    while read -r c; do [ -n "$c" ] && crunning "$c" && users+=("$c"); done \
      < <(docker ps -a -q --filter "volume=$vol")
    [ "${#users[@]}" -gt 0 ] && docker stop ${users+"${users[@]}"} >/dev/null 2>&1
  fi

  f="$OUT/volumes/$(slug "$vol").tar.gz"
  if docker run --rm -v "$vol":/data:ro -v "$OUT/volumes":/backup alpine \
       tar czf "/backup/$(basename "$f")" -C /data . >/dev/null 2>&1 && [ -s "$f" ]; then
    bytes=$(stat -c%s "$f"); sum=$(sha256sum "$f" | cut -d' ' -f1)
    printf '%s\t%s\t%s\t%s\n' "$vol" "volumes/$(basename "$f")" "$bytes" "$sum" >> "$MAN_VOL"
    ok "$vol  $(numfmt --to=iec "$bytes" 2>/dev/null || echo "$bytes")"
    VOL_OK=$((VOL_OK + 1))
  else
    warn "$vol: tar failed"; rm -f "$f"
  fi

  [ "${#users[@]}" -gt 0 ] && docker start ${users+"${users[@]}"} >/dev/null 2>&1
done < <(docker volume ls -q)

# ── 5. the files a git clone will never give you back ────────────────────────
step "Project .env files"
if [ "$COPY_ENV" -eq 0 ]; then
  warn "skipped (--no-env). This snapshot cannot be restored without the passwords."
else
  ENV_N=0
  # One working_dir per compose project, deduplicated.
  while read -r wd; do
    [ -n "$wd" ] && [ -d "$wd" ] || continue
    proj=$(basename "$wd")
    while IFS= read -r e; do
      rel="${e#"$wd"/}"
      (umask 077 && mkdir -p "$OUT/env/$proj/$(dirname "$rel")") || continue
      cp -p "$e" "$OUT/env/$proj/$rel" && ENV_N=$((ENV_N + 1))
    done < <(find "$wd" -maxdepth 2 -name '.env' -o -maxdepth 2 -name '.env.*' \
             -not -name '.env.example' -not -name '.env.sample' 2>/dev/null)
  done < <(docker ps -a --format '{{.ID}}' |
           xargs -r -n1 -I{} docker inspect {} \
             --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null |
           grep -v '^$' | sort -u)
  ok "$ENV_N .env file(s) copied  - THIS SNAPSHOT NOW HOLDS SECRETS"
fi

# ── 6. manifest ──────────────────────────────────────────────────────────────
step "Manifest"
{
  printf 'taken     %s\n' "$(date -u +'%Y-%m-%d %H:%M:%SZ')"
  printf 'host      %s\n' "$(uname -n)"
  printf 'os        %s\n' "$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
  printf 'docker    %s\n' "$(docker --version 2>/dev/null)"
  printf 'databases %s/%s\n' "$PG_OK" "$PG_N"
  printf 'volumes   %s/%s\n' "$VOL_OK" "$VOL_N"
  printf '\ncompose projects and where they lived:\n'
  docker ps -a --format '{{.ID}}' |
    xargs -r -n1 -I{} docker inspect {} \
      --format '  {{index .Config.Labels "com.docker.compose.project"}}	{{index .Config.Labels "com.docker.compose.project.working_dir"}}' 2>/dev/null |
    grep -v '	$' | sort -u
  printf '\nimages in use (re-pull these):\n'
  docker ps -a --format '  {{.Image}}' | sort -u
} > "$OUT/manifest.txt"
cat "$OUT/manifest.txt" | sed 's/^/    /'

steps_end
rule
bar "$((PG_OK + VOL_OK))" "$((PG_N + VOL_N))" "artifacts written"
[ "$PG_OK" -eq "$PG_N" ] || warn "$((PG_N - PG_OK)) database(s) were NOT dumped - read the warnings above"
info "Snapshot: $OUT"
info "Restore with: ./scripts/db-restore.sh '$OUT'"
warn "Contains secrets. Copy it somewhere that is NOT only the external drive."
