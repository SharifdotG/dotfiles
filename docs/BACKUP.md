# Backup & Restore

**Read this from your phone or a second machine.** Half of it runs before the disk is erased
and half after, and between those two halves this file is not on the laptop.

`docs/MIGRATION.md` is the runbook — the ordering, the gates, the one-shot decisions. This is
the reference for the three scripts it calls, and the place to look when one of them says
something you did not expect.

---

## What these scripts exist for

A `git clone` restores your code. `bootstrap.sh` restores your configuration. Between them
they miss exactly three things, and all three are on the disk you are about to erase:

| | Why a clone cannot bring it back |
|---|---|
| **The Dockerised databases** | Data, not code. Nothing in git has ever held it. |
| **The projects' `.env` files** | Gitignored *by design*. `git status` is clean and they are still unique. |
| **Agent config — MCP tokens, skills** | Lives in `~/.claude.json`, `~/.codex/`, `~/.gemini/`; none of it is in any repo. |

Two commands cover all three:

```bash
./scripts/db-backup.sh              # databases, volumes, and every project .env
./scripts/agents-backup.sh export   # MCP servers, skills, rules, settings
```

Measured on this machine, 2026-09-04: **10 MB total**, twelve seconds. It is small because it
is *logical* — dumps and manifests, not disk images.

> **Both outputs contain secrets** — the `.env` files, Postgres role password hashes, and live
> bearer tokens for four MCP servers. They are written `0700`/`0600` under `~/Backup/`, which
> is outside this repo on purpose. Never move them into the tree; it is public.

---

## Part 1 — Before you install CachyOS

### Step 1. Back up the databases

```bash
./scripts/db-backup.sh
```

Writes `~/Backup/db/<UTC timestamp>/`. Nothing needs to be running first — it starts what it
needs and puts your containers back exactly as it found them.

**What it finds by itself.** No list to maintain; it reads Docker:

| Found | Treated as |
|---|---|
| `structflow-postgres-1` · `postgres:17-alpine` · db `structflow` | `pg_dump -Fc` |
| `tryton-postgres-1` · `postgres:16` · db `tryton` | `pg_dump -Fc` |
| `keycloak-postgres` · `postgres:15` · db `keycloak` | `pg_dump -Fc` |
| `structflow_minio-data` and 3 other named volumes | `tar`, containers stopped |
| anonymous 64-hex volumes | skipped — nothing a rebuild will not recreate |
| every compose project's `.env` | copied into `env/` |

**Keycloak is the one people forget.** It holds every realm, client and user for the
SocialHousing stack. Without it that stack comes up and nobody can log in.

> **Why Postgres gets dumps and everything else gets tarballs.** Two independent reasons, and
> either alone is enough. A tar of a *live* `PGDATA` is a torn snapshot: it restores cleanly,
> passes a smoke test, and corrupts at the first checkpoint. And a `PGDATA` directory is bound
> to its **major version** — this machine runs 15, 16 and 17 side by side, so a `postgres:15`
> volume cannot be opened by a 17 server and there is no in-place path across a reinstall.

> **NB — the script never runs `docker start` on your containers.** `structflow-postgres-1`
> and `tryton-postgres-1` both publish host port **5432**, so starting the stopped one fails
> whenever the other is up — which is most of the time. The first version of this script did
> exactly that and silently skipped Tryton's 227 MB database. A stopped cluster is read through
> a *throwaway* container on the same image and volume, publishing nothing. It also works if
> the container has since been deleted.

**Expected output.** Three `ok` lines for databases, four for volumes, `3/3` in the manifest:

```
--- pg_dump
  ok structflow/structflow  5.1M  (postgres:17-alpine)
    keycloak-postgres    stopped - reading keycloak_postgres_data through a throwaway postgres:15
  ok keycloak/keycloak  206K  (postgres:15)
    tryton-postgres-1    stopped - reading tryton_postgres-data through a throwaway postgres:16
  ok tryton/tryton  3.0M  (postgres:16)
```

If the last line of the run says *"N database(s) were NOT dumped"*, **stop and read the
warnings.** The summary bar counts every database it found, not just the ones that worked.

### Step 2. Back up the agents

```bash
./scripts/agents-backup.sh export
```

Writes `~/Backup/claude/`. Captures MCP servers at both scopes, `~/.claude/skills`,
`~/.agents/skills`, `rules/`, `settings.json`, the installed-plugin *list*, and a raw copy of
what Codex and Antigravity already have.

> **Why not just copy `~/.claude.json`?** It is 79 KB of which the MCP config is a few hundred
> bytes. The rest is *this machine's identity* — `machineID`, `userID`, onboarding flags,
> per-project history, cached feature flags. Restoring it wholesale carries the old machine's
> identity onto the new one and overwrites what the fresh install already wrote.

> **Why not just copy `~/.claude`?** It is 294 MB, of which 249 MB is `projects/` —
> conversation transcripts — and 37 MB is a re-installable plugin cache. The part that is
> genuinely configuration is a few megabytes.

**It will warn, and the warnings are correct.** On this machine:

- `spartan-ui` and `pencil` — stdio servers whose binaries do not exist. Dead already.
- **14 dead skill links dropped by name** — `angular-developer`, the `stripe-*` set, the
  `seo-*` set and friends are symlinks to `/c/Users/SharifdotG/…` from the Windows machine.
  `/c` does not exist here. A plain `tar` would archive fourteen dangling links and faithfully
  restore them, still dead.

Prune those from `~/.claude/skills` while you are moving; nothing else will.

### Step 3. The things no script covers

Sweep these by hand — per byte they are the most valuable things on the disk:

- **Gitignored files beyond `.env`.** `db-backup.sh` catches every compose project's `.env`
  automatically. It does **not** catch `appsettings.Development.json`, local dev certs,
  `*.pfx`, `docker-compose.override.yml`, `secrets.json`. Per repo:
  ```bash
  git ls-files --others --ignored --exclude-standard -- . ':!node_modules'
  ```
- **`kwallet`.** Export it. A fresh install starts with an empty wallet, always.
- **The credential files this repo excludes on purpose** — `~/.npmrc`,
  `~/.nuget/NuGet.Config`, `~/.docker/config.json`, `~/.config/gh/hosts.yml`.
- **Your Brave sync code.** `brave://settings/braveSync` → *View Sync Code*. Twenty-four words,
  written somewhere that is not this laptop.
- **2FA recovery codes.** Sync never carries cookies or sessions, so you *will* be logged out
  of everything. This is the one that actually ruins a day.

### Step 4. Get it off the machine

```bash
du -sh ~/Backup/db/* ~/Backup/claude
```

About 10 MB. Copy it to the external drive **and somewhere else** — a private repo, a cloud
drive, a phone. At the moment it matters, the external drive is a single point of failure.

### Gate — do not start the install until all four pass

1. `db-backup.sh` reported **3/3** databases, not 2/3.
2. `agents-backup.sh show` lists your servers and skills.
3. The gitignored sweep is done and its output is a directory you can list.
4. The backups exist **in two places**, at least one of which is not the external drive.

---

## Part 2 — After CachyOS is installed

**The order is the content.** Each step needs the one before it:

```bash
# 1. the repo itself
git clone https://github.com/SharifdotG/dotfiles.git ~/dotfiles && ~/dotfiles/bootstrap.sh
sudo ~/dotfiles/system/apply.sh

# 2. bring the backups back
cp -a /run/media/<you>/BACKUP/Backup ~/Backup

# 3. agents - works immediately, needs nothing else
cd ~/dotfiles
./scripts/agents-backup.sh restore -i ~/Backup/claude

# 4. credentials, BEFORE any clone - SocialHousingOSS is on a private forge
#    also restore by hand: ~/.npmrc, ~/.nuget/NuGet.Config, ~/.docker/config.json, ~/.config/gh/
./scripts/secrets-setup.sh          # gh auth login (HTTPS + token)
./scripts/git-credentials.sh        # a PAT per host, into kwallet - github.com
                                    # and the private forge. Both remotes are
                                    # HTTPS; no SSH key is involved anywhere.

# 5. clone your project repos under ~/Documents/Code
#    ~/Documents/Code/structflow, ~/Documents/Code/SocialHousingOSS/..., ...
#    The paths no longer have to match the old machine exactly - see
#    "When the code tree moves" below.

# 6. docker, then the databases
sudo usermod -aG docker "$USER"     # then log out and back in - this is the half
                                    # no script can finish for you
sudo ./system/apply.sh              # writes daemon.json AND enables docker.socket
                                    # (the socket, not the service: dockerd starts
                                    # on first use, not at boot)
./scripts/db-restore.sh ~/Backup/db/<stamp> --list    # read-only. Always do this first
./scripts/db-restore.sh ~/Backup/db/<stamp>

# 7. the rest of each stack
cd ~/Documents/Code/structflow && docker compose up -d
```

> **Why step 5 comes before step 6.** The database restore puts each project's `.env` back into
> its project directory and runs `docker compose up -d <db service>` there. With no clone,
> there is nowhere to put the `.env` and nothing to bring up — the script will tell you
> *"project directory not found — clone it first, then re-run"* and skip that project.

> **Why step 4 comes before step 5.** `SocialHousingOSS` lives on a private forge
> (`internal-git.siderian.cloud`), so the clone needs a credential that the fresh install does
> not have. Issue **new** tokens rather than carrying the old ones — the wallet does not
> survive the wipe either way, so there is nothing to carry.

> **Why the browser comes last, or at least after Phase 4.** The first thing that stresses a
> fresh machine is the restore itself. Do not do it on an untuned 16 GB box; see
> `docs/MIGRATION.md` Stage 5.

> **If a restore reports a tally smaller than the snapshot holds, read this.** Until
> **2026-09-06** `confirm()` used a bare `read`, which reads **stdin** — and both callers sit
> inside `while read … done < "$MANIFEST"` loops, where stdin *is* the manifest. The prompt never
> reached the terminal: it consumed **the next row of the manifest** as the answer, that row was
> never `y`, and the loop skipped the database it had just silently eaten. A three-database
> snapshot reported `0/2 databases restored` with `keycloak` absent from the output entirely, and
> four volumes showed up as two. **Every interactive run was unable to restore anything**; only
> `--yes` worked, because it returns before reading. `confirm()` now reads the terminal on a
> dedicated fd and the loops read on fd 3, so neither the prompt nor any `docker` call in the
> loop body can eat a row.
>
> A run with no controlling terminal and no `--yes` now **fails fast with one message** instead
> of skipping every row and printing `0/N`, which read like a corrupt snapshot.

### When the code tree moves

A snapshot records each project's directory as the **absolute path it had at backup time**,
taken from docker's `com.docker.compose.project.working_dir` label. That is historical fact and
the snapshot is never rewritten — but it goes stale the moment the code tree moves, and then
every path in every existing snapshot is wrong at once.

This happened on **2026-09-06**, moving `~/Documents/Code/VSCode` → `~/Documents/Code` — one
segment shallower. A restore of a snapshot taken two days earlier skipped *everything*:

```
▸ [2/5] Project .env files
  ▲ structflow: project directory not found - clone it first, then re-run
  ✓ 0 placed, 3 skipped
▸ [4/5] Databases
  ▲ structflow: no container 'structflow-postgres-1' and no project directory at
    '/home/sharifdotg/Documents/Code/VSCode/structflow'

  ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░  0/2 databases restored
```

Nothing was wrong with the snapshot. Every project was on disk, one directory over.

`db-restore.sh` now treats the recorded path as a **starting point, not an answer**, and says so
when it relocates one:

```
    structflow moved    /home/…/Code/VSCode/structflow -> /home/…/Code/structflow
```

Three strategies, most trustworthy first:

1. **The recorded path still exists** — use it verbatim, no search.
2. **`--remap OLD=NEW`** (repeatable) — an explicit prefix rewrite. This outranks the search
   below on purpose: an operator saying where something went is better evidence than anything
   the script can infer.
3. **Search under `--code-root`** (default `~/Documents/Code`, or `$CODE_ROOT`) for the
   **longest trailing part** of the recorded path that exists there:

   ```
   recorded  /home/me/Documents/Code/VSCode/SocialHousingOSS/tryton
   tries     $CODE_ROOT/home/me/Documents/Code/VSCode/SocialHousingOSS/tryton
             …
             $CODE_ROOT/SocialHousingOSS/tryton     <- hit, and specific
             $CODE_ROOT/tryton                      <- never reached
   ```

   Longest-first is what keeps this honest. Taking the shortest match would happily bind a
   project called `tryton` sitting anywhere in the tree. A candidate that also holds a compose
   file wins outright; a bare directory is only a fallback.

> **The search only ever shortens the recorded path — it never hunts recursively.** So a project
> that moved *deeper* (gained a new parent directory) will not be found automatically, by design:
> that is where a wrong guess would be plausible and expensive. Use `--remap` for it.

Nothing needs doing for **future** snapshots: `db-backup.sh` reads the working directory from the
live docker label every run, so it records wherever the project is now.

### What `db-restore.sh` actually does

In this order, and it stops at the first sign of trouble rather than half-writing:

1. **Verifies every checksum before writing anything.** A damaged artifact aborts the run.
2. **Puts the `.env` files back** — never overwriting one that already exists.
3. **Extracts the non-Postgres volumes**, emptying each first so a stale file cannot survive
   and masquerade as live data.
4. **Brings up only the database service** of each stack — not the whole stack, so the app
   cannot start writing before its data is in.
5. **`pg_restore`s**, prompting once per database.

> **`pg_restore` exits 1 when it ignored errors and still finished.** That is neither success
> nor failure. The script reports which of the three happened rather than printing a tick over
> a partial load. If you see *"restored WITH ERRORS"*, read them before trusting that database.

### What `agents-backup.sh restore` actually does

One export, three agents. The servers are translated into the shape each one really reads:

| Agent | File | Format |
|---|---|---|
| Claude Code | `~/.claude.json` → `.mcpServers` | JSON |
| Codex | `~/.codex/config.toml` → `[mcp_servers.<name>]` | TOML, in a managed block |
| Antigravity 2.0 | `~/.gemini/config/mcp_config.json` → `.mcpServers` | JSON |

**Skills are installed once** into `~/.agents/skills` and symlinked into each agent's skills
directory — `~/.claude/skills`, `~/.codex/skills`, `~/.gemini/config/skills`. That is already
the pattern this machine uses for 13 of its skills, and it is the only arrangement where
editing a skill updates all three instead of leaving three copies to drift.

> **Codex gets a marked block, not a parsed edit.** This repo has no TOML tool and `jq` cannot
> do TOML, so the servers go between `# >>> agents-backup.sh managed block >>>` and its
> closing marker, rewritten whole on every run. It is idempotent, it never touches a line you
> wrote yourself, and a server you already defined by hand outside the block is detected and
> skipped — a second `[mcp_servers.X]` table would be a duplicate-key parse error, not a merge.

> **Codex picks the transport from the keys, not a `type` field.** `url` means streamable
> HTTP, `command` means stdio, and headers are `http_headers`.

> **The restore is also a repair.** All 27 symlinks in `~/.gemini/config/skills` are dead:
> whatever populated it copied Claude Code's link text verbatim without adjusting for the extra
> directory level, so `../../.agents/skills/X` resolves to `~/.gemini/.agents/…`. Antigravity
> can currently see only the three skills that happen to be real directories. The script writes
> the correct depth and replaces dangling links **without** needing `--force`, because a
> dangling link is not something that was put there deliberately.

**Dead servers are skipped by default** — `--all` keeps them. A dead stdio server is a startup
error in every agent that loads it.

### Verify

```bash
claude mcp list
codex mcp list
ls -l ~/.gemini/config/skills | head        # every link should resolve
docker compose ps                            # per project
```

Then log into Brave with the 24 words, and expect to re-authenticate everything — that is
normal and unavoidable.

---

## Reference

### Where things land

```
~/Backup/db/<UTC stamp>/
├── databases.tsv          project · service · container · image · db · user · file · bytes · sha256 · workdir
├── volumes.tsv            volume · file · bytes · sha256
├── manifest.txt           host, OS, docker version, compose project paths, image list
├── pg/
│   ├── <project>__<db>.dump          pg_dump -Fc
│   └── <project>__<db>.globals.sql   roles; NOT applied unless you pass --globals
├── volumes/<name>.tar.gz
└── env/<project>/.env

~/Backup/claude/
├── mcp-servers.json       user scope + project scope
├── skills.tar.gz          ~/.claude/skills, dead links dropped
├── agents-skills.tar.gz   ~/.agents/skills - what the good links point at
├── config.tar.gz          settings.json, settings.local.json, rules/, plugin lists
├── codex-config.toml      raw copies of what the other two already had,
├── antigravity-*.json     for reference and rollback only - the restore
└── gemini-settings.json   re-derives both from mcp-servers.json
```

### Flags worth knowing

| Script | Flag | Use it when |
|---|---|---|
| `db-backup.sh` | `-o DIR` | writing straight to the external drive |
| | `--live` | you cannot afford to stop MinIO. Postgres is never tarred either way |
| | `--no-env` | you want a snapshot with no secrets in it — then you must supply the passwords by hand at restore |
| `db-restore.sh` | `--list` | **always, first.** Read-only |
| | `--only PROJECT` | one stack at a time — `structflow`, `tryton`, `keycloak` |
| | `--yes` | unattended; skips the per-database confirmation |
| | `--globals` | rarely. Only if a database needs roles the compose entrypoint does not create |
| `agents-backup.sh` | `show` | inspect an export with the keys redacted |
| | `--agents LIST` | `claude`, `codex`, `antigravity` — any subset |
| | `--all` | keep servers whose command is missing *here* but will exist later |
| | `--force` | overwrite what is already on the new machine |

### Deliberately not backed up

| | Why |
|---|---|
| Docker images and build cache | 9 GB + 7.5 GB. Re-pull from the manifest's image list; `docker save` **only** the locally-built ones (`structflow-*`, `vera_api-*`, `config-mapper-*`) |
| `~/.claude/projects` (249 MB) | conversation transcripts. Copy separately if you want them |
| `~/.claude/plugins` cache (37 MB) | re-installable. The *list* is in `config.tar.gz`; use `/plugin install` |
| `node_modules`, `obj/`, `bin/`, `~/.nuget`, `~/.npm-global` | native modules compiled against a specific glibc and Node ABI. Restoring them across a distro change gives you packages that load and then segfault |
| The Brave profile (1.5 GB) | Sync covers it. 1.1 GB of it is regenerable Service Worker and IndexedDB cache anyway |
| Anonymous 64-hex Docker volumes | nothing a rebuild will not recreate |

### Proving a backup is real

*A backup you have never restored from is a hypothesis.* Restore a dump into a throwaway
server — it touches nothing you own:

```bash
SNAP=~/Backup/db/<stamp>
docker volume create verify
c=$(docker run -d --rm -v verify:/var/lib/postgresql/data \
      -e POSTGRES_PASSWORD=verify -e POSTGRES_USER=structflow -e POSTGRES_DB=structflow \
      postgres:17-alpine)
until docker exec "$c" pg_isready -h 127.0.0.1 -U structflow -d structflow; do sleep 1; done
docker exec -i "$c" pg_restore -U structflow -d structflow --clean --if-exists \
  --no-owner --no-privileges < "$SNAP/pg/structflow__structflow.dump"
docker exec "$c" psql -U structflow -d structflow -tAc \
  "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 5"
docker rm -f "$c"; docker volume rm verify
```

Done for all three on 2026-09-04: structflow 73 tables / 39,971 rows in `outbox_messages`,
keycloak 87 tables, tryton 540.

> **NB — `pg_isready` must be asked over `-h 127.0.0.1`, not the unix socket.** While the
> official image initialises a volume it runs a *temporary* socket-only server; a socket-based
> check calls that ready, and a restore started on its word dies partway through with
> `FATAL: the database system is shutting down`, having already loaded some of the data.
> Socket-only is precisely how the image marks that phase.

---

## Troubleshooting

| It says | It means |
|---|---|
| `N database(s) were NOT dumped` | Read the warnings above it. The summary counts what it *found*, not what worked. |
| `never became ready - SKIPPED` | The server did not come up in 60s. The script prints its last log lines; usually a corrupt volume or an image that no longer exists locally. |
| `stopped, but <vol> is mounted by a running container` | Two containers share one data volume. Stop the other one and re-run. |
| `dump is not a readable pg archive - DISCARDED` | `pg_dump` wrote a fragment. The file is deleted rather than kept — a truncated dump that *looks* fine is worse than none. |
| `checksum mismatch` (restore) | The snapshot is damaged. Nothing has been written yet. Use your second copy. |
| `project directory not found - clone it first` | Step 4 of Part 2 was skipped. Clone, then re-run with `--only <project>`. |
| `restored WITH ERRORS` | `pg_restore` finished but ignored errors. Read them; the database may be incomplete. |
| `codex: [mcp_servers.X] already defined by hand` | You wrote that server into `config.toml` yourself. Yours wins. Delete it if you want the export's version. |
| `still dangling: <skill>` | `~/.agents/skills` did not restore. Check `agents-skills.tar.gz` is in the export. |
| `a claude process is running` | Claude Code may rewrite `~/.claude.json` and undo the merge. Quit it and re-run. |
