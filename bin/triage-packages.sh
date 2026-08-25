#!/usr/bin/env bash
# Classify every package Omarchy wants against what actually exists for aarch64.
#
# Produces packages/triage.tsv with one of four verdicts per package:
#   alarm   - in the Arch Linux ARM aarch64 repos; just pacman -S it
#   omarchy - Omarchy ships a PKGBUILD for it; we must build it for aarch64
#   aur     - only in the AUR; we must build it for aarch64
#   drop    - x86_64-only or hardware-irrelevant on a uConsole; excluded
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../config/build.env"
source "$HERE/lib.sh"

step "Package triage for aarch64"
DB="$CACHE_DIR/repodb"; mkdir -p "$DB"
MIRROR="http://mirror.archlinuxarm.org/aarch64"

# --- what Arch Linux ARM has for aarch64 -----------------------------------
: > "$DB/alarm-packages.txt"
for repo in core extra alarm aur; do
  f="$DB/$repo.db"
  if [[ ! -s "$f" ]]; then
    info "fetching $repo.db"
    curl -sfL --max-time 120 "$MIRROR/$repo/$repo.db" -o "$f" || { warn "no $repo repo"; continue; }
  fi
  # Entries are directories named <pkg>-<ver>-<rel>/; strip the two trailing fields.
  tar tf "$f" 2>/dev/null | grep '/$' | sed 's|/$||' \
    | sed -E 's/-[^-]+-[^-]+$//' >> "$DB/alarm-packages.txt"
done
sort -u -o "$DB/alarm-packages.txt" "$DB/alarm-packages.txt"
info "Arch Linux ARM aarch64 provides $(wc -l < "$DB/alarm-packages.txt") packages"

# Provides/replaces are not in the name list, so record those too.
: > "$DB/alarm-provides.txt"
for repo in core extra alarm aur; do
  [[ -s "$DB/$repo.db" ]] || continue
  tar xOf "$DB/$repo.db" --wildcards '*/desc' 2>/dev/null \
    | awk '/^%PROVIDES%/{p=1;next} /^%[A-Z]+%/{p=0} p&&NF{sub(/[<>=].*/,"");print}' >> "$DB/alarm-provides.txt"
done
sort -u -o "$DB/alarm-provides.txt" "$DB/alarm-provides.txt"

# --- what Omarchy builds itself --------------------------------------------
PKGS_SRC="$CACHE_DIR/omarchy-pkgs"
if [[ ! -d "$PKGS_SRC/.git" ]]; then
  info "cloning omarchy-pkgs"
  git clone --depth 1 "$OMARCHY_PKGS_REPO" "$PKGS_SRC" >/dev/null 2>&1
fi
ls "$PKGS_SRC/pkgbuilds" > "$DB/omarchy-packages.txt" 2>/dev/null || : > "$DB/omarchy-packages.txt"
info "omarchy-pkgs carries $(wc -l < "$DB/omarchy-packages.txt") PKGBUILDs"

# --- packages we deliberately refuse to carry ------------------------------
# Kept as a data file rather than inline so the reasons are reviewable.
DROPLIST="$HERE/../packages/excluded.packages"

# --- classify ---------------------------------------------------------------
OMARCHY_SRC="$CACHE_DIR/omarchy"
[[ -d "$OMARCHY_SRC/.git" ]] || git clone --depth 1 --branch "$OMARCHY_REF" "$OMARCHY_REPO" "$OMARCHY_SRC" >/dev/null 2>&1

out="$HERE/../packages/triage.tsv"
{
  printf 'package\tverdict\tsource_list\treason\n'
  for list in omarchy-base omarchy-other; do
    src="$OMARCHY_SRC/install/${list}.packages"
    [[ -f "$src" ]] || continue
    grep -vE '^\s*(#|$)' "$src" | while read -r pkg; do
      pkg="${pkg%%[[:space:]]*}"
      [[ -n "$pkg" ]] || continue
      if reason=$(grep -E "^${pkg}\b" "$DROPLIST" 2>/dev/null | head -1 | cut -d'|' -f2- | sed 's/^ *//'); [[ -n "$reason" ]]; then
        printf '%s\tdrop\t%s\t%s\n' "$pkg" "$list" "$reason"
      elif grep -qxF "$pkg" "$DB/alarm-packages.txt"; then
        printf '%s\talarm\t%s\tin Arch Linux ARM aarch64 repos\n' "$pkg" "$list"
      elif grep -qxF "$pkg" "$DB/alarm-provides.txt"; then
        printf '%s\talarm\t%s\tprovided by another aarch64 package\n' "$pkg" "$list"
      elif grep -qxF "$pkg" "$DB/omarchy-packages.txt"; then
        printf '%s\tomarchy\t%s\tomarchy-pkgs PKGBUILD; must be built for aarch64\n' "$pkg" "$list"
      else
        printf '%s\taur\t%s\tnot in aarch64 repos or omarchy-pkgs; AUR build required\n' "$pkg" "$list"
      fi
    done
  done
} > "$out"

step "Triage result"
tail -n +2 "$out" | cut -f2 | sort | uniq -c | sort -rn | while read -r n v; do
  info "$(printf '%-8s %s' "$v" "$n")"
done
ok "wrote $out"
