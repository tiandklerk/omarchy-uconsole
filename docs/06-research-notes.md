# Research notes

The findings this design rests on, with the checks that produced them. Recorded
because several of them contradict the obvious assumption, and anyone picking
this up later will otherwise re-derive them the hard way.

## 1. Rex's uConsole work is Debian, not Arch

The starting assumption for this project was that ak-rex publishes an Arch build
for the CM5 uConsole to fork. He does not. His repositories are:

- `ak-rex/ClockworkPi-pi-gen` — pi-gen (Debian Trixie/Bookworm) image builder
- `ak-rex/akrex-arm-repo` — an **APT** repository (`bookworm/`, `debian/`)
- `ak-rex/rpi-linux` — a Raspberry Pi kernel fork

So there is no Arch userland to inherit. **What is reusable is the kernel**, and
that is the part that matters: hardware enablement is distro-independent.

The Debian-only pieces we must replace with Arch equivalents are his
`clockworkpi-audio` and `uconsole-4g` packages, and his `rc.local`-based tweaks.

## 2. The kernel tree carries everything, and its defconfig already enables it

`ak-rex/rpi-linux` branch `rpi-6.12.y` (6.12.95) contains:

```
arch/arm/boot/dts/overlays/clockworkpi-uconsole-cm5-overlay.dts
drivers/gpu/drm/panel/panel-cwu50.c          # the 480x1280 DSI panel
drivers/video/backlight/ocp8178_bl.c         # backlight
```

and — the pleasant surprise — `arch/arm64/configs/bcm2712_defconfig` already
sets `CONFIG_DRM_PANEL_CWU50=m`, `CONFIG_BACKLIGHT_OCP8178=m`,
`CONFIG_MFD_AXP20X_I2C=y`, `CONFIG_BATTERY_AXP20X=m`. A plain
`bcm2712_defconfig` build is a working uConsole kernel. Our config fragment only
adds what *Arch* wants (systemd, containers, zram), not what the hardware wants.

Branch `rpi-7.1.y` also exists and is newer (July 2026). We default to 6.12.y
because it is the branch Rex actually ships images from, and therefore the one
with real-world testing behind it.

## 3. Omarchy's default branch is `quattro`, not `master`

```
$ gh api repos/basecamp/omarchy --jq .default_branch
quattro
```

`master` is Omarchy **3.8.5**; `quattro` is **4.0.0.alpha**. This matters twice
over: v4 is the current line, and v3 carries a `uname -m` guard that refuses to
install on anything but x86_64 — which v4 dropped.

An early version of the package triage in this repo cloned `master` and
silently produced a package list for the wrong Omarchy. `config/build.env` now
pins `quattro` with a comment explaining why.

## 4. Omarchy's aarch64 repository exists but is empty

`omacom-io/omarchy-pkgs` advertises multi-architecture support and documents the
exact `tonistiigi/binfmt --install arm64` workflow this repo uses. The published
result, however, is not there yet:

| Repository | Packages |
|---|---|
| `https://pkgs.omarchy.org/x86_64/omarchy.db` | **202** |
| `https://pkgs.omarchy.org/aarch64/omarchy.db` | **1** (`omarchy-keyring`) |

`edge/aarch64` and `stable/aarch64` 404 entirely. So the aarch64 packages must
be built locally — which is what stage 30 does. We still register the upstream
aarch64 repo, because `omarchy-keyring` is genuinely there and the repo should
fill out over time.

## 5. The port is much smaller than it looks

Triaging all 210 packages in Omarchy's lists against the Arch Linux ARM aarch64
repositories (13,262 packages):

| Verdict | Count |
|---|---|
| Already in Arch Linux ARM aarch64 | 136 |
| Deliberately dropped (x86-only hardware) | 45 |
| Must be built from `omarchy-pkgs` | 20 |
| Must be built from the AUR | 7 |

**27 packages to build, not 202.** And `omarchy` and `omarchy-settings` — the
two packages that *are* Omarchy — are both `arch=('any')`, so they need no
porting at all. Of the 20 `omarchy-pkgs` builds, only three
(`hyprland-preview-share-picker`, `tensaku`, `tzupdate`) are tagged x86_64-only,
and all three build from source, so the tag is likely just untested rather than
a real limitation. Stage 30 adds `aarch64` to such PKGBUILDs and reports what
actually fails.

## 6. Panel geometry

From Rex's kanshi profile and X11/labwc rotation snippets, the panel is
**480x1280@60 mounted rotated**, presented as 1280x480 landscape via a **270°**
transform, on output `DSI-1` *or* `DSI-2` depending on which lane the CM5 brings
up. Both are configured; Hyprland ignores rules for absent outputs.

Console rotation is separate and comes from `fbcon=rotate:1` on the kernel
command line.

## 7. No initramfs is needed

`bcm2712_defconfig` builds `CONFIG_EXT4_FS=y`, `CONFIG_MMC_BLOCK=y`,
`CONFIG_MMC_BCM2835=y` and `CONFIG_MMC_SDHCI_IPROC=y` — all built in, not
modules. The kernel can therefore mount the SD card root unaided, and the boot
path is just firmware → `config.txt` → kernel → root. Dropping mkinitcpio from
the picture removes a large class of ARM boot failures.

The panel driver *is* a module, so the display lights up a moment after boot
rather than at the first kernel message. That matches ClockworkPi's own images.
