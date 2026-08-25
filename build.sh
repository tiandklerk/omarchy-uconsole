#!/usr/bin/env bash
# omarchy-uconsole - build a flashable Omarchy image for the ClockworkPi
# uConsole with a Raspberry Pi Compute Module 5.
#
#   ./build.sh              run every stage in order
#   ./build.sh kernel       run a single stage (kernel|rootfs|omarchy|image)
#   ./build.sh --from omarchy   run from that stage to the end
#
# Stages are resumable: each reuses what the previous one left in work/ and
# out/, so a failed run can be restarted without redoing the hours before it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT_DIR/config/build.env"
source "$ROOT_DIR/bin/lib.sh"

STAGES=(kernel rootfs omarchy image)
declare -A STAGE_DIR=(
  [kernel]=10-kernel [rootfs]=20-rootfs [omarchy]=30-omarchy [image]=40-image
)

usage() { sed -n '2,10p' "$0" | sed 's/^# \?//'; exit "${1:-0}"; }

selected=("${STAGES[@]}")
case "${1:-}" in
  -h|--help) usage ;;
  --from)
    [[ -n "${2:-}" ]] || die "--from needs a stage name"
    start=-1
    for i in "${!STAGES[@]}"; do [[ "${STAGES[$i]}" == "$2" ]] && start=$i; done
    (( start >= 0 )) || die "unknown stage '$2' (want: ${STAGES[*]})"
    selected=("${STAGES[@]:$start}")
    ;;
  "") ;;
  *)
    [[ -n "${STAGE_DIR[$1]:-}" ]] || die "unknown stage '$1' (want: ${STAGES[*]})"
    selected=("$1")
    ;;
esac

# --- preflight -------------------------------------------------------------
require_cmd docker "docker is required"
require_cmd git
require_arm64_emulation
require_disk_gb 30 "$ROOT_DIR"

mkdir -p "$CACHE_DIR" "$WORK_DIR" "$OUT_DIR"

step "omarchy-uconsole"
info "model:   $UC_MODEL"
info "kernel:  $KERNEL_BRANCH from $KERNEL_REPO"
info "omarchy: $OMARCHY_REF"
info "stages:  ${selected[*]}"

# Triage has to be current before rootfs/omarchy can pick package sets.
if [[ ! -f "$ROOT_DIR/packages/triage.tsv" ]]; then
  "$ROOT_DIR/bin/triage-packages.sh"
fi

started=$SECONDS
for stage in "${selected[@]}"; do
  s0=$SECONDS
  "$ROOT_DIR/stages/${STAGE_DIR[$stage]}/build.sh"
  ok "stage '$stage' finished in $(( (SECONDS - s0) / 60 ))m $(( (SECONDS - s0) % 60 ))s"
done

# A structural check is cheap and catches assembly mistakes that would
# otherwise only show up as a uConsole that does not boot.
if [[ -f "$OUT_DIR/${IMG_NAME}.img" ]]; then
  "$ROOT_DIR/bin/verify-image.sh" || warn "image verification reported problems"
fi

step "done in $(( (SECONDS - started) / 60 ))m"
[[ -d "$OUT_DIR" ]] && ls -lh "$OUT_DIR"/*.img* 2>/dev/null | sed 's/^/    /'
