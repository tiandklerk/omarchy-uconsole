# The uConsole, driver by driver

What the hardware is, what drives it, and where each piece is configured in this
repository. Target is the **CM5** carrier; CM4 differences are noted.

## Compute module

**Raspberry Pi Compute Module 5**, BCM2712 (Cortex-A76 ×4), with the RP1 south
bridge handling GPIO, I2C and USB. The reference build is a **CM5 Lite, 16 GB
RAM, WiFi** — Lite means no eMMC, so the system boots from microSD.

Kernel target: `bcm2712_defconfig`, aarch64.

## Boot path

The CM5 has no BIOS or UEFI. The bootloader lives in SPI EEPROM on the module,
reads `config.txt` from the FAT partition, loads the device tree and the kernel,
and jumps to it. There is no bootloader on disk to install or configure.

This is why Omarchy's limine bootloader — and the snapshot-rollback boot entries
built on it — do not come along. See [03-not-included.md](03-not-included.md).

Configured in: `overlay/boot/config.txt`, `overlay/boot/cmdline.txt`.

## Display

A **480×1280 60 Hz MIPI DSI panel**, physically mounted rotated 90° in the
shell, so it reads as 1280×480 landscape.

- Panel driver: `panel-cwu50` (`CONFIG_DRM_PANEL_CWU50`)
- Enabled by: `dtoverlay=clockworkpi-uconsole-cm5`
- Rotation, console: `fbcon=rotate:1` on the kernel command line
- Rotation, Wayland: `transform = 3` (270°) in
  `overlay/skel/.config/hypr/monitors.lua`

The output enumerates as `DSI-1` or `DSI-2` depending on kernel version and
which lane comes up; both are configured.

`ignore_lcd=1` in `config.txt` stops the firmware trying to probe this as a
standard Raspberry Pi touch display.

### Consequences of a 1280×480 screen

This is the single most invasive fact about the device. 480 vertical pixels is
about a third of a laptop's, and Omarchy's defaults assume a laptop:

- `GDK_SCALE` is dropped from Omarchy's default of `2` to `1`
- Gaps, borders and rounding are tightened in
  `overlay/skel/.config/hypr/looknfeel.lua`
- Blur and shadows are disabled — they cost VideoCore VII time and buy nothing
  at this size

## Backlight

**OCP8178**, driven by `ocp8178_bl` (`CONFIG_BACKLIGHT_OCP8178`), exposed at
`/sys/class/backlight/`. `brightnessctl` drives it, which is what Omarchy's
brightness keys call.

A udev rule in `overlay/etc/udev/rules.d/99-uconsole-power.rules` gives the
`video` group write access to `brightness`, so brightness keys work without
root.

## Power and battery

**AXP228 PMIC** over I2C (`x-powers,axp228`), declared in the device-tree
overlay. It supplies the panel, audio and WiFi rails, and manages charging.

- `CONFIG_MFD_AXP20X_I2C=y`, `CONFIG_BATTERY_AXP20X=m`, `CONFIG_CHARGER_AXP20X=m`
- Battery appears as a standard power supply, so UPower — and therefore
  Omarchy's battery indicator — works with no special handling

**Charge current**: the PMIC defaults low enough that a CM5 under load drains
while plugged in. The udev rule raises it to 2.0 A (2.2 A max), matching
ClockworkPi's own images:

```
KERNEL=="axp20x-battery", ATTR{constant_charge_current_max}="2200000", ATTR{constant_charge_current}="2000000"
```

## Keyboard and trackball

A membrane matrix keyboard and an optical trackball, presented by the
ClockworkPi HID firmware. Both come up through the device-tree overlay as
standard input devices — no userspace driver.

Tuned in `overlay/skel/.config/hypr/input.lua`: slower key repeat (the matrix
rattles at Omarchy's default rate) and raised pointer sensitivity (the trackball
is small relative to a 1280 px-wide screen).

## Audio

Routed through the PMIC's codec to GPIO 12/13:

```
dtparam=audio=on
dtoverlay=audremap,pins_12_13
```

Rex's Debian images ship a `clockworkpi-audio` package for mixer defaults. There
is no Arch equivalent; if levels are wrong on first boot this is the most likely
reason. See [05-first-boot.md](05-first-boot.md).

## WiFi and Bluetooth

The CM5's on-board Broadcom/Cypress CYW43455 via `brcmfmac`. No DKMS module and
no `broadcom-wl` — that package is x86-only and unnecessary here.

**WiFi** works from `linux-firmware`, which carries both the chip firmware
(`brcmfmac43455-sdio.bin`) and — importantly — the board-specific NVRAM for this
exact module, `brcmfmac43455-sdio.raspberrypi,5-compute-module.txt`. Without a
matching NVRAM file the radio does not come up, so this was verified explicitly
rather than assumed.

**Bluetooth needs a blob Arch does not ship.** The CYW43455's Bluetooth side
loads `BCM4345C0.hcd`, which Raspberry Pi distributes separately (in
`RPi-Distro/bluez-firmware`) and which is absent from Arch's `linux-firmware` —
so wifi would work and Bluetooth would silently not. Stage 20 fetches
`BCM4345C0.hcd` and `BCM4345C5.hcd` into `/usr/lib/firmware/brcm/`.

**`dtparam=ant2` matters.** It selects the external antenna connector fitted in
the uConsole shell instead of the module's on-board antenna. Without it, range
is poor.

## USB

`dtoverlay=dwc2,dr_mode=host` — the internal hub is host-only.

## Storage

microSD (`mmcblk0`) on a CM5 Lite. Root is ext4, grown to fill the card on first
boot by `uconsole-firstboot-resize.service`.

ext4 rather than btrfs: Omarchy's btrfs setup exists to serve limine-based
snapshot rollback, which has no bootloader to hook into here, and ext4 can be
grown in place with `resize2fs`.

## 4G modem

Some uConsoles carry a 4G module. Rex ships a `uconsole-4g` Debian package for
it. **This repository does not support it** — no Arch equivalent has been
written. ModemManager is not installed and the modem is untested.
