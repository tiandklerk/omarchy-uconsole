#!/usr/bin/env bash
# Stage 10 - build the uConsole kernel, modules, device trees and overlays.
#
# Output (into $OUT_DIR/kernel):
#   kernel8-uconsole.img   the flat aarch64 Image the RPi firmware loads
#   dtbs/                  base device trees (bcm2712-rpi-cm5*.dtb et al)
#   overlays/              *.dtbo, including clockworkpi-uconsole-cm5.dtbo
#   modules/               a /usr/lib/modules tree to drop into the rootfs
#   kernel.release         e.g. 6.12.95-uconsole-cm5
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$HERE/../../config/build.env"
source "$HERE/../../bin/lib.sh"

step "Stage 10: kernel ($KERNEL_BRANCH, $UC_MODEL)"

SRC="$CACHE_DIR/rpi-linux"
OUT="$OUT_DIR/kernel"

defconfig_var="UC_DEFCONFIG_${UC_MODEL}"
DEFCONFIG="${!defconfig_var:?unknown UC_MODEL '$UC_MODEL'}"

# --- fetch source ----------------------------------------------------------
if [[ ! -d "$SRC/.git" ]]; then
  info "cloning $KERNEL_REPO ($KERNEL_BRANCH) - this is ~2 GiB"
  git clone --depth 1 --single-branch --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$SRC"
else
  info "reusing kernel source at $SRC"
fi

# Sanity-check that this really is a tree with uConsole support, so a wrong
# KERNEL_REPO fails here instead of producing an image that never lights up.
require_file "$SRC/arch/arm/boot/dts/overlays/clockworkpi-uconsole-${UC_MODEL}-overlay.dts" \
  "kernel tree has no clockworkpi-uconsole-${UC_MODEL} overlay - wrong KERNEL_REPO/BRANCH?"
require_file "$SRC/drivers/gpu/drm/panel/panel-cwu50.c" \
  "kernel tree has no CWU50 panel driver - wrong KERNEL_REPO/BRANCH?"

build_image "$IMG_CROSS" "$HERE"

mkdir -p "$OUT"
KBUILD="$WORK_DIR/kbuild"          # out-of-tree build dir, keeps $SRC pristine
MODROOT="$WORK_DIR/kmodules"
mkdir -p "$KBUILD" "$MODROOT"

run_in "$IMG_CROSS" \
  -v "$SRC:/build/src:ro" \
  -v "$KBUILD:/build/out" \
  -v "$MODROOT:/build/modroot" \
  -v "$HERE:/build/stage:ro" \
  -e "DEFCONFIG=$DEFCONFIG" \
  # NOT named LOCALVERSION: the kernel Makefile appends an environment
  # LOCALVERSION on top of CONFIG_LOCALVERSION, which silently doubles the
  # suffix (6.12.95-uconsole-cm5-uconsole-cm5).
  -e "UC_LOCALVERSION=$KERNEL_LOCALVERSION" \
  -e "JOBS=$JOBS" \
  -- \
  bash -euo pipefail -c '
    cd /build/src
    M="make -j${JOBS} O=/build/out ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"

    echo "==> ${DEFCONFIG}"
    $M "${DEFCONFIG}"

    echo "==> merging omarchy config fragment"
    # merge_config.sh scribbles temp files into $PWD, and /build/src is a
    # read-only mount, so run it from the build directory.
    ( cd /build/out && /build/src/scripts/kconfig/merge_config.sh -m -O /build/out \
        /build/out/.config /build/stage/omarchy.config )

    # Pin the version suffix so modules land in a uConsole-specific directory
    # and never collide with a stock Arch kernel.
    ./scripts/config --file /build/out/.config --set-str LOCALVERSION "${UC_LOCALVERSION}"
    ./scripts/config --file /build/out/.config --disable LOCALVERSION_AUTO
    $M olddefconfig

    echo "==> verifying the uConsole drivers survived olddefconfig"
    for sym in CONFIG_DRM_PANEL_CWU50 CONFIG_BACKLIGHT_OCP8178 CONFIG_MFD_AXP20X_I2C CONFIG_BATTERY_AXP20X; do
      if ! grep -qE "^${sym}=(y|m)$" /build/out/.config; then
        echo "FATAL: ${sym} is not enabled - the panel/backlight/battery would not work" >&2
        exit 1
      fi
    done

    echo "==> Image modules dtbs"
    $M Image modules dtbs

    echo "==> installing modules"
    $M INSTALL_MOD_PATH=/build/modroot INSTALL_MOD_STRIP=1 modules_install
  '

# --- collect artifacts -----------------------------------------------------
KREL="$(cat "$KBUILD/include/config/kernel.release")"
info "kernel release: $KREL"

install -Dm644 "$KBUILD/arch/arm64/boot/Image" "$OUT/$KERNEL_IMAGE_NAME"
echo "$KREL" > "$OUT/kernel.release"

rm -rf "$OUT/dtbs" "$OUT/overlays" "$OUT/modules"
mkdir -p "$OUT/dtbs" "$OUT/overlays"

# Base device trees live in the aarch64 tree; the RPi firmware wants them flat
# in the root of the boot partition.
find "$KBUILD/arch/arm64/boot/dts/broadcom" -name '*.dtb' -exec cp {} "$OUT/dtbs/" \;
# Overlay *sources* live in the 32-bit tree and are shared, but an arm64 build
# emits the compiled .dtbo files under arch/arm64. Prefer that, and fall back to
# the 32-bit path so a differently-arranged tree still works.
OVL_SRC="$KBUILD/arch/arm64/boot/dts/overlays"
[[ -d "$OVL_SRC" ]] || OVL_SRC="$KBUILD/arch/arm/boot/dts/overlays"
require_file "$OVL_SRC" "no overlays directory in the build output"
cp "$OVL_SRC"/*.dtbo "$OUT/overlays/"
cp "$OVL_SRC/overlay_map.dtb" "$OUT/overlays/" 2>/dev/null || true

cp -a "$MODROOT/lib/modules" "$OUT/modules"
# The build symlinks point into the throwaway build dir; drop them.
rm -f "$OUT/modules/$KREL/build" "$OUT/modules/$KREL/source"

require_file "$OUT/overlays/clockworkpi-uconsole-${UC_MODEL}.dtbo" \
  "the uConsole overlay did not build"

ok "kernel $KREL"
info "  image:    $OUT/$KERNEL_IMAGE_NAME ($(du -h "$OUT/$KERNEL_IMAGE_NAME" | cut -f1))"
info "  dtbs:     $(ls "$OUT/dtbs" | wc -l) files"
info "  overlays: $(ls "$OUT/overlays" | wc -l) files"
info "  modules:  $(du -sh "$OUT/modules" | cut -f1)"
