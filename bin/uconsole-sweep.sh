#!/usr/bin/env bash
# Full health sweep of a running uConsole. Run this ON the device.
#
#   ./bin/uconsole-sweep.sh            human-readable
#   ./bin/uconsole-sweep.sh --brief    one line per check, for pasting
#
# Every check here corresponds to something that actually broke during bring-up,
# so a clean run means the specific ways this image has failed before are not
# failing now. It cannot tell you the device is perfect - only that the known
# traps are clear.
set -uo pipefail
BRIEF=0; [[ "${1:-}" == "--brief" ]] && BRIEF=1
pass=0; fail=0; warn=0

if [[ -t 1 ]] && (( ! BRIEF )); then
  G=$'\e[1;32m'; R=$'\e[1;31m'; Y=$'\e[1;33m'; D=$'\e[2m'; N=$'\e[0m'
else G=; R=; Y=; D=; N=; fi

# NOTE: `((var++))` returns the PRE-increment value as the exit status, which
# is falsy (1) exactly when var is 0 - i.e. on each counter's first call. That
# made the very first ok()/bad()/note() invocation in a run also fall through
# to the CALLER's `||` branch, so e.g. "board: ..." printed as both PASS and
# WARN for the same line. `var=$((var+1))` is an assignment; it always exits 0.
ok()   { printf "  ${G}PASS${N}  %s\n" "$1"; pass=$((pass+1)); }
bad()  { printf "  ${R}FAIL${N}  %s\n" "$1"; [[ -n "${2:-}" ]] && printf "        ${D}%s${N}\n" "$2"; fail=$((fail+1)); }
note() { printf "  ${Y}WARN${N}  %s\n" "$1"; [[ -n "${2:-}" ]] && printf "        ${D}%s${N}\n" "$2"; warn=$((warn+1)); }
sec()  { printf "\n${D}== %s ==${N}\n" "$1"; }

sec "Hardware"
model=$(tr -d '\0' < /proc/device-tree/model 2>/dev/null)
[[ "$model" == *"Compute Module 5"* ]] && ok "board: $model" || note "board: ${model:-unknown}"
k=$(uname -r); [[ "$k" == *uconsole* ]] && ok "kernel: $k" || bad "kernel: $k" "expected a -uconsole- kernel"

sec "Display"
for d in /sys/class/drm/card*-DSI-*; do
  [[ -e "$d/enabled" ]] || continue
  e=$(cat "$d/enabled"); s=$(cat "$d/status")
  [[ "$e" == enabled && "$s" == connected ]] \
    && ok "panel $(basename "$d"): $e/$s" \
    || note "panel $(basename "$d"): $e/$s" "normal if the screen is currently blanked"
done
[[ -e /dev/dri/renderD128 ]] && ok "GPU render node present (v3d)" \
  || bad "no /dev/dri/renderD128" "Mesa will fall back to llvmpipe and nothing will draw"
lsmod | grep -q '^panel_cwu50' && ok "panel driver loaded" || bad "panel-cwu50 not loaded"

sec "Input"
grep -q "Clockwork uConsole Keyboard" /proc/bus/input/devices && ok "keyboard present" || bad "keyboard not found"
grep -q "uConsole Keyboard Mouse" /proc/bus/input/devices && ok "trackball present" || note "trackball not found"
if command -v udevadm >/dev/null; then
  # Which /dev/input/eventN is "Clockwork uConsole Keyboard" shifts between
  # boots (HID enumeration order is not guaranteed), so check every keyboard
  # interface rather than a hardcoded node.
  found=0
  for d in /sys/class/input/event*; do
    [[ "$(cat "$d/device/name" 2>/dev/null)" == "Clockwork uConsole Keyboard" ]] || continue
    e="/dev/input/$(basename "$d")"
    udevadm info --query=property --name="$e" 2>/dev/null | grep -q "KEYBOARD_KEY_700e2=leftmeta" && { found=1; break; }
  done
  (( found )) && ok "Super key remap applied (Left Alt)" \
    || bad "Super key remap not applied on any keyboard interface"
fi

sec "Network"
ip -br addr show scope global 2>/dev/null | grep -q UP && ok "an interface is up" || bad "no interface up"
[[ -f /usr/lib/firmware/brcm/brcmfmac43455-sdio.bin ]] && ok "wifi firmware present" \
  || bad "wifi firmware MISSING" "the radio will not start"
[[ -f /usr/lib/firmware/brcm/BCM4345C0.hcd ]] && ok "bluetooth firmware present" || note "bluetooth firmware missing"
getent hosts github.com >/dev/null 2>&1 && ok "DNS resolves" || bad "DNS not resolving" "check /etc/resolv.conf is a symlink"

sec "Packages"
orph=$(pacman -Qtdq 2>/dev/null)
# Benign build-time orphans (mkinitcpio, and anything pulled in as a makedepend
# by first-boot provisioning or a `yay -S`) are expected - that is the entire
# reason omarchy-update-orphan-pkgs exists, to let the user clean them up. The
# only orphan that actually matters is firmware, which uconsole-firmware exists
# to pin against; check that specifically rather than failing on any orphan.
fw_orphan=$(grep '^linux-firmware' <<<"$orph" || true)
if [[ -n "$fw_orphan" ]]; then
  bad "firmware is orphaned: $(tr '\n' ' ' <<<"$fw_orphan")" "omarchy update will offer to DELETE it; uconsole-firmware should prevent this"
elif [[ -n "$orph" ]]; then
  note "benign orphans present: $(tr '\n' ' ' <<<"$orph")" "expected after any package build; safe to clean via omarchy update's orphan prompt"
else
  ok "no orphans"
fi
pacman -Q uconsole-firmware >/dev/null 2>&1 && ok "uconsole-firmware pins the firmware" \
  || bad "uconsole-firmware meta-package missing" "firmware can be orphaned and deleted"
for p in mise-bin yay xdg-terminal-exec omarchy omarchy-settings; do
  pacman -Q "$p" >/dev/null 2>&1 && ok "$p installed" || bad "$p MISSING"
done

sec "Audio"
aplay -l 2>/dev/null | grep -q "RP1-Audio-Out" && ok "RP1 audio device present" || bad "no RP1 audio device"
grep -q "^dtoverlay=audremap-pi5" /boot/config.txt 2>/dev/null && ok "CM5 audio overlay set" \
  || bad "audremap-pi5 not in config.txt" "plain audremap is inert on a CM5"
grep -q "^gpio=11=op,dh" /boot/config.txt 2>/dev/null && ok "amp enable in config.txt" || bad "gpio=11 missing"
if systemctl is-enabled uconsole-audio-amp >/dev/null 2>&1; then
  st=$(systemctl is-active uconsole-audio-amp)
  [[ "$st" == active ]] && ok "amp gating running (idle hiss suppressed)" || note "amp gating $st"
else note "amp gating not enabled" "expected on images built after 2026-09-01"; fi

sec "Power"
cap=$(cat /sys/class/power_supply/axp20x-battery/capacity 2>/dev/null)
[[ -n "$cap" ]] && ok "battery reports ${cap}%" || bad "no battery reading"
cc=$(cat /sys/class/power_supply/axp20x-battery/constant_charge_current 2>/dev/null)
# The AXP228 only accepts current in ~150000uA steps from a 300000uA base, so
# a udev rule requesting 2000000 legitimately lands on the driver's nearest
# step, 1950000 - confirmed by the step arithmetic, not a rounding bug.
[[ "${cc:-0}" -ge 1900000 ]] && ok "charge current ${cc} (raised from the too-low default)" \
  || note "charge current ${cc:-unknown}" "well below the requested rate; may drain while plugged in"
# The kernel keeps offering these states regardless of our config (this
# device'"'"'s kernel predates the CONFIG_SUSPEND removal); what actually stops a
# hard lock is every *reachable* path being blocked: the sleep targets are
# masked (systemctl suspend fails outright) and the menu'"'"'s "Sleep" entry calls
# uconsole-lock-and-blank, never systemctl suspend. Check both explicitly
# rather than trusting the kernel capability list alone.
if [[ -z "$(cat /sys/power/state 2>/dev/null)" ]]; then
  ok "suspend disabled at the kernel (no states offered)"
else
  masked=1
  for t in sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target; do
    [[ "$(systemctl is-enabled "$t" 2>/dev/null)" == "masked" ]] || masked=0
  done
  if (( masked )); then
    note "kernel offers sleep states ($(cat /sys/power/state)) but all systemd sleep targets are masked" \
      "s2idle hard-locks this hardware; masking blocks every reachable path to it"
  else
    bad "kernel offers sleep states AND sleep targets are not all masked" \
      "systemctl suspend would reach s2idle, which hard-locks this hardware"
  fi
fi

sec "Desktop"
systemctl is-active sddm >/dev/null 2>&1 && ok "sddm running" || bad "sddm not running"
pgrep -x Hyprland >/dev/null && ok "Hyprland running" || note "Hyprland not running"
pgrep -f quickshell >/dev/null && ok "omarchy shell running" || note "omarchy shell not running"

printf "\n${D}--------------------------------${N}\n"
printf "  ${G}%d passed${N}   ${R}%d failed${N}   ${Y}%d warnings${N}\n" "$pass" "$fail" "$warn"
(( fail )) && exit 1 || exit 0
