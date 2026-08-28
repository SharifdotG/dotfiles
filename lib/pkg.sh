# shellcheck shell=bash
# Resolve logical package ids to this distro's real package names.
# Deliberately awk+TSV: a fresh machine has coreutils and awk and nothing else.
# Requiring `yq` in order to install `yq` is a bootstrap cycle.
pkg_resolve() {
  local col="$1"; shift
  awk -F'\t' -v want="$col" '
    $1 == "#id" { for (i = 2; i <= NF; i++) if ($i == want) c = i; next }
    /^#/ || NF == 0 { next }
    { if (c && $c != "" && $c != "-" && $c != "skip") print $c }
  ' "$@" | sort -u
}
# Ids the manifest says this distro cannot provide from its repos.
pkg_unavailable() {
  local col="$1"; shift
  awk -F'\t' -v want="$col" '
    $1 == "#id" { for (i = 2; i <= NF; i++) if ($i == want) c = i; next }
    /^#/ || NF == 0 { next }
    { if (c && $c == "-") print $1 }
  ' "$@" | sort -u
}
