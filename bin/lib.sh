#!/usr/bin/env bash
# Shared helpers for the omarchy-uconsole build stages.

if [[ -t 1 ]]; then
  _C_STEP=$'\e[1;35m'; _C_OK=$'\e[1;32m'; _C_WARN=$'\e[1;33m'
  _C_ERR=$'\e[1;31m';  _C_DIM=$'\e[2m';   _C_OFF=$'\e[0m'
else
  _C_STEP=; _C_OK=; _C_WARN=; _C_ERR=; _C_DIM=; _C_OFF=
fi

step() { printf '\n%s==> %s%s\n' "$_C_STEP" "$*" "$_C_OFF"; }
info() { printf '%s    %s%s\n'   "$_C_DIM"  "$*" "$_C_OFF"; }
ok()   { printf '%s  ✓ %s%s\n'   "$_C_OK"   "$*" "$_C_OFF"; }
warn() { printf '%s  ! %s%s\n'   "$_C_WARN" "$*" "$_C_OFF" >&2; }
die()  { printf '%s  ✗ %s%s\n'   "$_C_ERR"  "$*" "$_C_OFF" >&2; exit 1; }

require_file() {
  [[ -e "$1" ]] || die "${2:-missing required file: $1}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "${2:-required command not found: $1}"
}

# Build a stage's container image if its Dockerfile is newer than the image.
build_image() {
  local tag="$1" ctx="$2"
  step "container image: $tag"
  docker build -q -t "$tag" "$ctx" >/dev/null
  ok "$tag ready"
}

# Run a command inside a container as the invoking user, so build artifacts on
# the bind mounts do not come back owned by root.
#   run_in <image> [docker opts...] -- <command...>
run_in() {
  local image="$1"; shift
  local -a opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  docker run --rm -i \
    -u "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    "${opts[@]}" "$image" "$@"
}

# Same, but as root inside the container (needed for pacman and loop devices).
#   run_in_root <image> [docker opts...] -- <command...>
run_in_root() {
  local image="$1"; shift
  local -a opts=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do opts+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  docker run --rm -i "${opts[@]}" "$image" "$@"
}

# Confirm that this host can execute aarch64 binaries. Every stage after the
# kernel depends on it, and the failure mode without it ("exec format error")
# is opaque, so check explicitly and tell the user how to fix it.
require_arm64_emulation() {
  if [[ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
    die "aarch64 emulation is not registered on this host.
    Run:  docker run --privileged --rm tonistiigi/binfmt --install arm64
    (this must be repeated after every reboot)"
  fi
  if ! docker run --rm --platform linux/arm64 alpine uname -m 2>/dev/null | grep -q aarch64; then
    die "aarch64 emulation is registered but not working; re-run:
    docker run --privileged --rm tonistiigi/binfmt --install arm64"
  fi
}

# Free space guard - the full pipeline needs a lot of room and running out
# halfway through wastes hours.
require_disk_gb() {
  local need="$1" path="${2:-.}" avail
  avail=$(df -BG --output=avail "$path" | tail -1 | tr -dc '0-9')
  (( avail >= need )) || die "need ${need}G free on $path, only ${avail}G available"
}
