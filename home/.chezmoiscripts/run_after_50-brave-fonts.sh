#!/usr/bin/env bash
# Write the four font families into Brave's own profile, because fontconfig
# cannot reach them.
#
# THE BUG THIS EXISTS FOR. .config/fontconfig/fonts.conf binds sans-serif,
# serif and monospace to Adwaita Sans / Adwaita Sans / CaskaydiaCove Nerd Font,
# and every fontconfig client honours it. Blink does not. Chromium maps the CSS
# generics to its OWN preferences and only then asks fontconfig for whatever
# concrete family those name:
#
#     webkit.webprefs.fonts.standard.Zyyy    <- pages that set no font at all
#     webkit.webprefs.fonts.serif.Zyyy       <- CSS `serif`
#     webkit.webprefs.fonts.sansserif.Zyyy   <- CSS `sans-serif`
#     webkit.webprefs.fonts.fixed.Zyyy       <- CSS `monospace`
#
# Two of those four were set on this machine (by hand, through Brave's settings
# UI, and therefore on no other machine); `standard` and `serif` were not. When
# a Chromium pref is unset it does not fall through to fontconfig - it uses
# Chromium's compiled-in default, which for both of those is "Times New Roman",
# which fontconfig then metric-substitutes to Liberation Serif. Measured in
# Brave headless against this profile, reading the face actually used to render
# via CSS.getPlatformFontsForNode:
#
#     (no font-family at all)  ->  Liberation Serif
#     font-family: serif       ->  Liberation Serif
#
# So an unstyled page rendered in a SERIF face on a desktop that is Adwaita Sans
# everywhere else. After this script: both -> Adwaita Sans.
#
# Zyyy is the ISO 15924 code for "common/undetermined" script, which is the
# generic per-script slot Chromium's own settings UI writes. The per-script
# slots (Hans, Jpan, ...) are left alone deliberately - CJK wants a CJK face,
# and Noto CJK is already the fallback fonts.conf appends.
#
# WHY THIS IS A run_after_ AND NOT A run_onchange_. Every other script in this
# directory is run_onchange_ with its guard inputs in a `state:` line, and that
# pattern CANNOT express what this one needs. Brave rewrites Preferences from
# memory while it runs, so a write landing during a session is discarded at
# exit; the only safe move is to skip and try again later. run_onchange_ records
# its hash on ANY zero exit, so "skipped because Brave was running" would be
# pinned in as the final answer and the prefs would never be written - the exact
# trap 40-default-apps documents, except here the guard's input (a running
# browser) is not something a state line can usefully hash, because it flips
# several times a day and would re-run this constantly anyway. run_after_ runs
# every apply, which is what "retry until it sticks" actually needs. The cost is
# one file read per apply, and the script is silent when nothing needs doing.
#
# HOW TO VERIFY, since the settings UI shows the effective value and not whether
# the pref is set, and fc-match cannot see any of this:
#     brave-origin --headless=new --remote-debugging-port=9222 \
#       --user-data-dir=/tmp/probe about:blank
# then read CSS.getPlatformFontsForNode for a node with no font-family.
# Or, in the running browser: brave://settings/fonts.

set -uo pipefail

UI_FAMILY="Adwaita Sans"
MONO_FAMILY="CaskaydiaCove Nerd Font"

# Brave's config root differs by package: brave-origin-bin (what packages/
# desktop.tsv installs) uses Brave-Origin, upstream brave-bin uses
# Brave-Browser. Both are checked so this is not silently a no-op if the package
# is ever swapped.
CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
ROOTS=(
  "$CONFIG_HOME/BraveSoftware/Brave-Origin"
  "$CONFIG_HOME/BraveSoftware/Brave-Browser"
)

if ! command -v python3 >/dev/null 2>&1; then
  echo "  brave-fonts: no python3 - skipping"
  exit 0
fi

# ── collect the profiles that actually exist ─────────────────────────────────
# Preferences only appears after the browser has been launched once. On a fresh
# machine there is nothing to patch and that is not a failure - the next apply
# after the first launch picks it up, which is the whole reason this is
# run_after_.
PROFILES=()
for root in "${ROOTS[@]}"; do
  [ -d "$root" ] || continue
  for prof in "$root"/Default "$root"/Profile\ *; do
    [ -f "$prof/Preferences" ] && PROFILES+=("$prof/Preferences")
  done
done

if [ "${#PROFILES[@]}" -eq 0 ]; then
  # Silent: this is the normal state on a machine where Brave has not been
  # started yet, and this script runs on EVERY apply.
  exit 0
fi

# ── would anything change? ───────────────────────────────────────────────────
# Asked before the "is Brave running" guard on purpose: when the prefs are
# already correct there is nothing to warn about, and nagging about a running
# browser on every single apply is how a warning gets ignored.
_needs_patch() { # _needs_patch <prefs file> -> 0 if a write is needed
  python3 - "$1" "$UI_FAMILY" "$MONO_FAMILY" <<'PY'
import json, sys
path, ui, mono = sys.argv[1], sys.argv[2], sys.argv[3]
want = {"standard": ui, "serif": ui, "sansserif": ui, "fixed": mono}
try:
    with open(path, encoding="utf-8") as fh:
        fonts = json.load(fh)["webkit"]["webprefs"]["fonts"]
except Exception:
    sys.exit(0)   # unreadable or key absent -> treat as needing a patch
sys.exit(1 if all(fonts.get(k, {}).get("Zyyy") == v for k, v in want.items()) else 0)
PY
}

TODO=()
for p in "${PROFILES[@]}"; do
  _needs_patch "$p" && TODO+=("$p")
done

[ "${#TODO[@]}" -eq 0 ] && exit 0

# ── do not write underneath a running browser ────────────────────────────────
# Chromium holds prefs in memory and serialises them back over this file on a
# timer and at shutdown. A write now is not corrupting - both sides rename a
# temp file into place - it is simply discarded, which is worse than not trying,
# because it looks like it worked.
if pgrep -x brave >/dev/null 2>&1 || pgrep -f 'brave-origin' >/dev/null 2>&1; then
  echo "  brave-fonts: Brave is running - fonts NOT written (would be discarded at exit)"
  echo "               quit Brave and re-run \`chezmoi apply\`"
  exit 0
fi

# ── patch ────────────────────────────────────────────────────────────────────
# Merge four keys, never rewrite the file wholesale. Preferences is a ~200 KB
# document owned by the browser and holding session state, extension records and
# per-site settings; the same rule as mimeapps.list in 40-default-apps applies.
# Written via a temp file + os.replace so an interrupted apply cannot leave a
# truncated Preferences behind, which WOULD lose the profile.
for p in "${TODO[@]}"; do
  if python3 - "$p" "$UI_FAMILY" "$MONO_FAMILY" <<'PY'
import json, os, sys, tempfile
path, ui, mono = sys.argv[1], sys.argv[2], sys.argv[3]
want = {"standard": ui, "serif": ui, "sansserif": ui, "fixed": mono}
with open(path, encoding="utf-8") as fh:
    prefs = json.load(fh)
fonts = prefs.setdefault("webkit", {}).setdefault("webprefs", {}).setdefault("fonts", {})
for generic, family in want.items():
    fonts.setdefault(generic, {})["Zyyy"] = family
# separators= matches how Chromium writes it: no spaces, no trailing newline.
d = os.path.dirname(path)
fd, tmp = tempfile.mkstemp(dir=d, prefix=".brave-fonts-")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(prefs, fh, separators=(",", ":"))
    os.replace(tmp, path)
except BaseException:
    os.path.exists(tmp) and os.unlink(tmp)
    raise
PY
  then
    echo "  brave-fonts: $UI_FAMILY / $MONO_FAMILY -> ${p%/Preferences}"
  else
    echo "  brave-fonts: WARNING - failed to patch $p"
  fi
done
