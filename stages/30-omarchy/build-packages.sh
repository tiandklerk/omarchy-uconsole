#!/usr/bin/env bash
# Runs inside the emulated aarch64 builder. Builds every queued package and
# writes a per-package verdict to /repo/build-report.tsv.
set -uo pipefail          # deliberately NOT -e: one bad PKGBUILD must not end the run

REPORT=/repo/build-report.tsv
PKGS_SRC=/cache/omarchy-pkgs
# Build under the bind-mounted work directory so makepkg logs survive the
# container and can be read from the host while a long build is in flight.
WORKDIR=/work/pkgbuild
say() { printf '\n\033[1;35m==> %s\033[0m\n' "$*"; }

mkdir -p "$WORKDIR"

# Packages we build here must be installable as dependencies of packages we
# build later - omarchy depends on omarchy-settings=<exact version>, and
# makepkg resolves that through pacman, not through the filesystem. So /repo is
# registered as a real pacman repository and refreshed after every success.
if ! grep -q '^\[uconsole-local\]' /etc/pacman.conf; then
  sudo tee -a /etc/pacman.conf >/dev/null <<'PACMAN'

[uconsole-local]
SigLevel = Optional TrustAll
Server = file:///repo
PACMAN
fi

refresh_local_repo() {
  ( cd /repo
    rm -f uconsole-local.db* uconsole-local.files*
    if compgen -G "*.pkg.tar."* > /dev/null; then
      repo-add --quiet uconsole-local.db.tar.gz *.pkg.tar.* >/dev/null 2>&1
    else
      # repo-add refuses to create an empty database, but pacman treats a
      # missing db as a hard sync failure and then resolves NO dependencies at
      # all - which looks exactly like a broken PKGBUILD. Hand-roll an empty
      # one so the repo is always valid, including before the first build.
      tar czf uconsole-local.db.tar.gz -T /dev/null
      ln -sf uconsole-local.db.tar.gz uconsole-local.db
    fi
  )
  sudo pacman -Sy --noconfirm >/dev/null 2>&1 || true
}

refresh_local_repo

printf 'package\tstatus\tdetail\n' > "$REPORT"

# Port patches: changes a PKGBUILD needs to be installable on this hardware,
# as opposed to merely buildable. Each one is a deliberate, documented
# divergence from upstream - keep the reasons here, not in a bare sed.
apply_port_patches() {
  local pkg="$1" dir="$2"

  case "$pkg" in
    omarchy)
      # omarchy depends on the limine bootloader and the snapper/btrfs
      # snapshot stack. On a Compute Module there is no ESP and no boot menu:
      # the firmware reads config.txt out of a FAT partition and jumps
      # straight to the kernel. limine-mkinitcpio-hook and limine-snapper-sync
      # are not even built for aarch64, so the dependency is unsatisfiable
      # rather than merely useless.
      #
      # Dropping them costs boot-menu snapshot rollback, which is documented
      # in docs/03-not-included.md. Nothing else in omarchy reads these.
      sed -i -E "/^[[:space:]]*'(limine|limine-mkinitcpio-hook|limine-snapper-sync|snapper)'[[:space:]]*$/d" \
        "$dir/PKGBUILD"
      echo "    (dropped limine/snapper dependencies - no bootloader on a Pi)"
      ;;
  esac
}

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

  apply_port_patches "$pkg" "$dir"

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
    # Match any compression: PKGEXT is normalised to .zst in the Dockerfile,
    # but a PKGBUILD is free to override it.
    if compgen -G "$dir/*.pkg.tar."* > /dev/null; then
      cp "$dir"/*.pkg.tar.* /repo/
      printf '%s\tbuilt\t%s\n' "$pkg" "$(cd "$dir" && ls *.pkg.tar.* | tr '\n' ' ')" >> "$REPORT"
      # Make it available to later packages that depend on it.
      refresh_local_repo
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
    echo "  FAILED $pkg: ${why:-unknown}"
  fi
  # Keep the log next to the report; drop the heavy intermediates.
  rm -rf "$dir/src" "$dir/pkg"
}

while read -r pkg; do
  [[ -n "$pkg" ]] || continue
  build_one "$pkg"
done < /work/build-list.txt

say "creating local pacman repository"
cd /repo
rm -f uconsole.db* uconsole.files*
if compgen -G "*.pkg.tar."* > /dev/null; then
  repo-add --quiet uconsole.db.tar.gz *.pkg.tar.*
fi

say "build report"
column -t -s $'\t' "$REPORT" 2>/dev/null || cat "$REPORT"
printf '\nbuilt: %s  failed: %s  unavailable: %s\n' \
  "$(awk -F'\t' '$2=="built"' "$REPORT" | wc -l)" \
  "$(awk -F'\t' '$2=="failed"' "$REPORT" | wc -l)" \
  "$(awk -F'\t' '$2=="unavailable"' "$REPORT" | wc -l)"
