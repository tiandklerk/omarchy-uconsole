# First boot and testing

Nothing here has been booted on hardware yet. This is the checklist to work
through, ordered so that each step's result narrows down the next.

## 0. Before you power on

Have a way to see failures that the panel cannot show you:

- **Serial** is the most useful. Add `enable_uart=1` to `config.txt` and
  `console=serial0,115200` to `cmdline.txt`, and attach a USB-TTL adapter to the
  uConsole's UART pins. This shows firmware and kernel output from the first
  instant.
- **A second card** with a known-good ClockworkPi image, so you can put the SD
  card in a reader and read `/boot` and the root filesystem after a failed boot.

## 1. Does the firmware start the kernel?

Symptom of failure: nothing at all, no backlight flicker.

The Pi bootloader reads `config.txt` and needs `kernel8-uconsole.img` and a
matching `bcm2712-*.dtb` on the FAT partition. Check on the card:

```bash
ls /path/to/boot/          # kernel8-uconsole.img, *.dtb, config.txt, cmdline.txt
ls /path/to/boot/overlays/ | grep clockworkpi
```

`clockworkpi-uconsole-cm5.dtbo` must be present. If it is missing the panel will
never come up regardless of anything else.

## 2. Does the kernel mount root?

Symptom: backlight comes on, then nothing, or a kernel panic on serial.

The root partition is referenced by `PARTUUID` in `cmdline.txt`, written at
image build time from the image's own MBR signature. Confirm it matches:

```bash
sudo blkid /dev/sdX2      # PARTUUID here...
cat /path/to/boot/cmdline.txt   # ...must match root=PARTUUID=
```

No initramfs is involved — ext4 and the SD driver are built into the kernel — so
a mismatch here is the only realistic root-mount failure.

## 3. Does the panel light up?

The panel driver is a **module**, so expect a beat between the first kernel
output and the display coming alive. If the console appears but rotated wrongly,
the fix is `fbcon=rotate:` in `cmdline.txt` (0/1/2/3).

If the panel stays dark but the system is otherwise alive (it responds on the
network, or serial shows a login prompt):

```bash
dmesg | grep -iE "cwu50|ocp8178|panel|dsi"
lsmod | grep -E "cwu50|ocp8178"
ls /sys/class/backlight/
```

## 4. Does Omarchy start?

```bash
systemctl status sddm
journalctl -b -u sddm
```

If sddm is not installed, stage 30 failed to build it or its dependencies —
check `out/packages/build-report.tsv` on the build host. You can still start
Hyprland from a TTY to test the graphics stack independently:

```bash
Hyprland
```

## 5. Is the display geometry right?

Inside Hyprland:

```bash
hyprctl monitors all
```

Expect a `DSI-2` output, mode `720x1280@59.901`, `transform: 3`, giving a
**1280×720** logical size.

If `hyprctl monitors` shows a mode that is not in `availableModes`, that is the
failure: the CRTC will read `enabled=disabled` in
`/sys/class/drm/card*-DSI-*/enabled` and nothing will be drawn. If the output is named something else, or the mode is
not offered, edit `~/.config/hypr/monitors.lua` to match what `hyprctl monitors
all` actually reports — that file is the single place this is configured.

### Lit panel, nothing drawn

Two distinct causes, both seen on the first real boot:

**No GPU.** Check `ls /dev/dri/` — if there is no `renderD128`, the v3d overlay
is missing and Mesa is on llvmpipe. The journal shows `EGL setup failed` and
`egl: failed to create dri2 screen`. Fix: `dtoverlay=vc4-kms-v3d-pi5` in
`config.txt`. The display works without it; the compositor does not.

**Wrong mode.** Check `cat /sys/class/drm/card*-DSI-*/enabled`. If it says
`disabled` while `status` says `connected`, a mode was requested that the panel
does not advertise. Compare `hyprctl monitors` against
`cat /sys/class/drm/card*-DSI-*/modes`. Fix: `mode = "preferred"`.

## 6. Hardware checks

| Thing | Check | Expect |
|---|---|---|
| Battery | `cat /sys/class/power_supply/axp20x-battery/capacity` | a percentage |
| Charging | `cat /sys/class/power_supply/*/status` while plugged in | `Charging` |
| Charge rate | `cat /sys/class/power_supply/axp20x-battery/constant_charge_current` | `2000000` |
| Backlight | `brightnessctl set 50%` | panel dims, no sudo needed |
| WiFi | `nmcli device wifi list` | networks, with decent signal |
| Audio | `wpctl status` then `speaker-test -c2 -t wav` | sound |
| Keyboard | type | keys land correctly |
| Trackball | move it | pointer moves at a usable speed |

**Charging is the one to watch.** If `constant_charge_current` reads lower than
2000000, the udev rule did not apply, and the uConsole will slowly discharge
while plugged in under load.

**WiFi range**: if signal is poor everywhere, `dtparam=ant2` may not have taken
effect — that switches to the uConsole's external antenna.

**Audio** is the most likely thing to be silently wrong. Rex's Debian images
ship a `clockworkpi-audio` package that sets mixer defaults; there is no Arch
equivalent here, so channels may start muted. Try `alsamixer` before concluding
it is broken.

## 7. Reporting back

Useful things to capture for any problem:

```bash
dmesg > dmesg.txt
journalctl -b > journal.txt
hyprctl monitors all > monitors.txt
```

Note which failed *first* — a dark panel and a dead sddm usually have one cause,
not two.
