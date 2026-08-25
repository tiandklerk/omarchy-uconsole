#!/usr/bin/env bash
# Runs inside the emulated aarch64 builder. Builds every queued package and
# writes a per-package verdict to /repo/build-report.tsv.
set -uo pipefail          # deliberately NOT -e: one bad PKGBUILD must not end the run

REPORT=/repo/build-report.tsv
PKGS_SRC=/cache/omarchy-pkgs
WORKDIR=/build
say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

sudo pacman -Sy --noconfirm >/dev/null

printf 'package\tstatus\tdetail\n' > "$REPORT"

build_one() {
  local pkg="$1" dir="$WORKDIR/$pkg"
  rm -rf "$dir"; mkdir -p "$dir"

  # Prefer Omarchy's own PKGBUILD; fall back to the AUR.
  if [[ -d "$PKGS_SRC/pkgbuilds/$pkg" ]]; then
    cp -a "$PKGS_SRC/pkgbuilds/$pkg/." "$dir/"
  elif git clone --depth 1 "https://aur.archlinux.org/$pkg.git" "$dir" >/dev/null 2>&1; then
    :
  else
    printf '%s\tunavailable\tno PKGBUILD in omarchy-pkgs and no AUR package\n' "$pkg" >> "$REPORT"
    return
  fi

  [[ -f "$dir/PKGBUILD" ]] || {
    printf '%s\tunavailable\tsource has no PKGBUILD\n' "$pkg" >> "$REPORT"; return
  }

  # Many of Omarchy's PKGBUILDs build from source but were only ever tagged
  # x86_64. Adding aarch64 lets us find out whether they actually build; if the
  # package is a prebuilt x86 binary it will fail below and be reported.
  if grep -qE "^arch=\(.*x86_64" "$dir/PKGBUILD" && ! grep -qE "^arch=\(.*aarch64" "$dir/PKGBUILD"; then
    sed -i -E "s/^arch=\((.*)\)/arch=(\1 'aarch64')/" "$dir/PKGBUILD"
    echo "    (added aarch64 to arch=())"
  fi

  say "building $pkg"
  local log="$WORKDIR/$pkg.log"
  if ( cd "$dir" && makepkg -sr --noconfirm --needed --skippgpcheck --nocheck ) > "$log" 2>&1; then
    if compgen -G "$dir/*.pkg.tar.zst" > /dev/null; then
      cp "$dir"/*.pkg.tar.zst /repo/
      printf '%s\tbuilt\t%s\n' "$pkg" "$(cd "$dir" && ls *.pkg.tar.zst | tr '\n' ' ')" >> "$REPORT"
      echo "  OK $pkg"
    else
      printf '%s\tfailed\tmakepkg succeeded but produced no package\n' "$pkg" >> "$REPORT"
    fi
  else
    # Keep the last meaningful error line so the report is actionable without
    # digging through logs.
    local why
    why=$(grep -iE "error|cannot|unable|not (available|supported)" "$log" | tail -1 | cut -c1-160)
    printf '%s\tfailed\t%s\n' "$pkg" "${why:-see $pkg.log}" >> "$REPORT"
    cp "$log" /repo/ 2>/dev/null
    echo "  FAILED $pkg: ${why:-unknown}"
  fi
  rm -rf "$dir/src" "$dir/pkg"
}

while read -r pkg; do
  [[ -n "$pkg" ]] || continue
  build_one "$pkg"
done < /work/build-list.txt

say "creating local pacman repository"
cd /repo
rm -f uconsole.db* uconsole.files*
if compgen -G "*.pkg.tar.zst" > /dev/null; then
  repo-add --quiet uconsole.db.tar.gz *.pkg.tar.zst
fi

say "build report"
column -t -s $'\t' "$REPORT" 2>/dev/null || cat "$REPORT"
printf '\nbuilt: %s  failed: %s  unavailable: %s\n' \
  "$(awk -F'\t' '$2=="built"' "$REPORT" | wc -l)" \
  "$(awk -F'\t' '$2=="failed"' "$REPORT" | wc -l)" \
  "$(awk -F'\t' '$2=="unavailable"' "$REPORT" | wc -l)"
