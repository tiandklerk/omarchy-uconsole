#!/usr/bin/env bash
# Stage 30 - build the Omarchy packages that do not exist for aarch64, then
# install Omarchy into the root filesystem.
#
# Every package is attempted independently. Failures are recorded in
# out/packages/build-report.tsv and do not stop the build, because a usable
# desktop that is missing one optional app is worth far more than no image.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../config/build.env"
source "$HERE/../../bin/lib.sh"

step "Stage 30: Omarchy for aarch64"
require_arm64_emulation
require_file "$WORK_DIR/rootfs/.extracted" "stage 20 has not run - no rootfs"

REPO_DIR="$OUT_DIR/packages"
mkdir -p "$REPO_DIR"

# --- what to build ---------------------------------------------------------
# The two packages that *are* Omarchy, plus everything triaged as needing a
# build. omarchy/omarchy-settings are arch=('any') so they need no porting.
BUILD_LIST="$WORK_DIR/build-list.txt"
# Order matters. omarchy depends on omarchy-settings=<exact version> and on
# ttf-jetbrains-mono-nerd-basic, both of which we build ourselves, and makepkg
# resolves dependencies through pacman against the local repo. So everything
# else is built first, then omarchy-settings, then omarchy last.
{
  awk -F'\t' '$2=="omarchy" || $2=="aur" {print $1}' "$HERE/../../packages/triage.tsv" \
    | grep -vxE 'omarchy|omarchy-settings'
  echo "omarchy-settings"
  echo "omarchy"
} > "$BUILD_LIST"
info "$(wc -l < "$BUILD_LIST") packages queued"

build_image "$IMG_ALARM_BUILD" "$HERE"

run_in_root "$IMG_ALARM_BUILD" \
  --platform linux/arm64 \
  -v "$WORK_DIR:/work" \
  -v "$CACHE_DIR:/cache" \
  -v "$REPO_DIR:/repo" \
  -v "$HERE/../..:/src:ro" \
  -e "JOBS=$JOBS" \
  -e "PKG_TIMEOUT=$PKG_TIMEOUT" \
  -e "OMARCHY_AARCH64_REPO_URL=$OMARCHY_AARCH64_REPO_URL" \
  -- bash -euo pipefail /src/stages/30-omarchy/build-packages.sh

# --- install into the rootfs ----------------------------------------------
run_in_root "$IMG_ALARM" \
  --privileged \
  -v "$WORK_DIR:/work" \
  -v "$REPO_DIR:/repo" \
  -v "$OUT_DIR:/out" \
  -v "$HERE/../..:/src:ro" \
  -e "OMARCHY_AARCH64_REPO_URL=$OMARCHY_AARCH64_REPO_URL" \
  -e "DEFAULT_USER=$DEFAULT_USER" \
  -- bash -euo pipefail /src/stages/30-omarchy/install-omarchy.sh

ok "Omarchy installed"
