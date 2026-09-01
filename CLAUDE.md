# omarchy-uconsole — context for Claude Code sessions

Read this before changing anything. It records what was learned building this,
most of it the hard way.

## What this is

A build pipeline producing a flashable Omarchy 4 image for a ClockworkPi
uConsole with a Raspberry Pi CM5. Four stages: kernel, rootfs, omarchy, image.
`./build.sh` runs them; `bin/verify-image.sh` checks the result.

**The image is built on an x86_64 host and runs on aarch64.** Package builds are
emulated (qemu-user via binfmt); the kernel is cross-compiled.

## If you are running ON the uConsole

You are on the target device, not the build host. Most of this repo is a build
system you cannot usefully run here — the useful bits are:

```bash
./bin/uconsole-sweep.sh          # full health check of this running device
./bin/uconsole-sweep.sh --brief  # terse, for pasting into a report
```

Every check in that script corresponds to something that has actually broken.

## Hard-won facts — do not rediscover these

**The panel is 1280x720, not 1280x480.** The 1280x480 ultrawide is the
*DevTerm*. ak-rex's kanshi config carries profiles for both devices, and taking
the wrong one cost a debugging session: the panel advertises exactly one mode
(`720x1280@59.901`), and naming any other leaves the CRTC disabled — backlight
lit, nothing drawn. Always use `mode = "preferred"`.

**The GPU is a separate overlay from the display.** `clockworkpi-uconsole-cm5`
brings up the DSI panel; without `vc4-kms-v3d-pi5` there is no render node, Mesa
falls back to llvmpipe, EGL fails and the compositor draws nothing onto a
working panel.

**The boot partition must be MBR type 0x0c.** `parted mkpart primary fat32` does
not reliably set it and left 0x83, which the Pi firmware cannot see: the board
is completely dead at power-on, no backlight, and every file on the card is
correct. Set the type byte explicitly.

**CM5 audio needs two things, each silent alone.** `audremap-pi5` (not
`audremap`, which is CM4/VPU-only and inert here), *and* `gpio=11=op,dh` to
power the speaker amp. With the wrong overlay the stream plays into a
`linux,spdif-dit` dummy codec and never reaches a pin, with no error anywhere.

**Suspend does not work.** `CONFIG_SUSPEND` was enabled and tested: s2idle
hard-locks the device, requiring a power cycle. This is why Raspberry Pi ships
`bcm2712_defconfig` without it. The sleep targets are masked deliberately.

**Omarchy deletes orphaned packages on every update.**
`omarchy-update-orphan-pkgs` runs `pacman -Rns` over `pacman -Qtdq`. Trimming
the `linux-firmware` meta-package orphaned the wifi firmware and an update
deleted it, leaving a device that detects its radio and cannot load firmware.
Marking packages explicit was **not** durable — the reason came back as a
dependency on a real device. The fix is `packages/uconsole-firmware`, a
meta-package that *depends* on the firmware. **Install reason is advisory;
a dependency is structural.**

**Omarchy's pacman config is x86-shaped.** `omarchy-apply-system` installs a
mirrorlist pointing at `mirror.omarchy.org` (x86_64 only), declares `[multilib]`
(nonexistent on aarch64), drops Arch Linux ARM's `[alarm]`/`[aur]`, and uses
`pkgs.omarchy.org/stable/$arch` where only `/aarch64` exists. Stage 30 rewrites
the repository list *after* apply-system, since that is what introduces it.

**Do not ship the build container's `/etc/resolv.conf`.** Both chroot stages
copy it in so pacman can reach the mirrors. Leaving it ships Docker's DNS
config and the device resolves nothing despite working wifi.

**modprobe.d is inert for built-in modules.** Omarchy's
`options usbcore autosuspend=-1` never applied because `usbcore` is built into
this kernel. Such settings must go on the kernel command line.

**Omarchy 4 uses Lua for Hyprland config**, not hyprland.conf, and its own
quickshell lock rather than hyprlock. `hyprctl keyword` is rejected; use
`hyprctl dispatch 'hl.dsp.dpms({ action = "enable" })'` and `o.bind(key, desc,
cmd, opts)`. User overrides that survive updates go in
`~/.config/omarchy/extensions/omarchy-menu.jsonc` — editing package-owned files
gets clobbered.

## Working practices

- **`bin/verify-image.sh` is the guard rail.** Every check exists because
  something shipped broken. If you change the build, run it. If you find a new
  failure mode, add a check — that is how this stays honest.
- **Building a package is not installing it.** That shipped twice
  (`xdg-terminal-exec`, then `mise-bin`). There is now a check for it.
- **Do not edit a script while it is executing.** Bash reads scripts
  incrementally; this corrupted a running build once.
- Watch disk. The rootfs and image coexist and each is ~8 GB.

## Open

- Repo is private pending a clean from-scratch flash test.
- Lock screen blanks while typing a password (cosmetic; the timeout is not
  exposed in Omarchy's `shell.json`).
- A generic Raspberry Pi 4/5 target: most of this is board-agnostic, and a plain
  Pi needs neither ak-rex's kernel nor the uConsole overlay. See the memory note
  on the base/layer split.
