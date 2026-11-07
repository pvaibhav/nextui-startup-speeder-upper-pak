# Userland boot time on stock TrimUI firmware

Not pursued. On 2026-11-08 we decided the gains are not worth patching this
many TrimUI and NextUI files, so Startup Speeder Upper stays at 1.0.0. The
experiments were undone on both Bricks. This page records what was tried.

The four changes, A to D, are described under "What each change does".

## Where NextUI's startup time goes

Brick Pro with a NextUI card, in seconds, medians of 2 to 3 boots, USB cable
attached.

| Stage | Stock | Speeder Upper 1.0.0 | + A to D | Who owns it |
|---|---|---|---|---|
| Bootloader | 6.68 | 1.85 | 1.88 | TrimUI |
| Kernel | ~4.2¹ | 1.85 | 1.85 | TrimUI |
| Userland until NextUI's launcher | ~1.6¹ | 1.39 | 1.30 | TrimUI |
| ↳ preinit scripts | | 0.26 | 0.26 | TrimUI |
| ↳ internal storage mount | | 0.48 | 0.48 | TrimUI |
| ↳ procd setup (coldplug, ubus) | | 0.25 | 0.25 | TrimUI |
| ↳ init scripts, early SD mount | | 0.40 | 0.31 | TrimUI |
| ↳ A, empty-slot check | | | 0 (card in) | TrimUI |
| ↳ B, USB switch | | | 0 (NextUI never runs it) | TrimUI |
| ↳ C, block hotplug filter | | | reverted (+0.07, noise) | TrimUI |
| ↳ D, hotplug shells | | | −0.09 (about noise) | TrimUI |
| NextUI's startup scripts | 3.06² | 1.15 | 1.15 | NextUI |
| NextUI app until the menu shows | ~2.2¹ | 2.17 | 1.97 (D) | NextUI |
| Menu visible | ~17.5¹ | 8.41 | 8.15 | |

¹ Estimate. The stock Pro was only timed until `nextui.elf` starts (15.6 s).
The kernel time comes from the stock Hammer, and the app time from the pak
state.

² Includes NextUI's launcher waiting for TrimUI's late SD mount.

On the Brick Hammer with stock MainUI and no card, A removed two 3.2 s card
waits and B removed a 1.05 s USB switch. The menu came 7.3 s sooner, at 7.4 s
after power-on instead of 14.7 s.

Most of what is left for NextUI is NextUI itself (3.1 s) and the kernel
(1.85 s).

## How it was measured

All runs are from 2026-11-07, on top of Startup Speeder Upper 1.0.0 in its
kept state. They used the BaseOS lab tool (`brick/dev/lab.py` in the BaseOS
repo) and the probes in `tools/probes/`. The results tables below use the
Linux clock, which counts seconds since the kernel started. Add the time
before Linux (1.6 s on the Hammer, 1.85 s on the Pro) to get the time since
power-on.

"Menu" is the first screen frame after the boot logo with a mean brightness
of at least 40 out of 255. `fbprobe` finds it by hashing a 32x24 pixel grid of
the shown frame buffer every 20 ms and logging each change.

The patches are in `userland-patches/`. They change only files on the overlay,
inside marked blocks. The BaseOS lab's decision log (`brick/work/decision.tsv`)
has a row for each attempt, U* rows for the Hammer and P* rows for the Pro.

## Results

| Change | Device and frontend | Menu before | Menu after |
|---|---|---|---|
| A, skip both launchers' card waits when the SD slot is empty | Hammer, stock MainUI, no card | 13.03 / 13.09 / 13.13 | 5.76 / 5.79 / 5.81, with B |
| B, TrimUI's launcher runs `usb_device.sh` in the background | Hammer, stock MainUI, no card | see A | see A |
| D, procd stops running `hotplug-call` for `platform` and `tty` events | Pro, NextUI, exFAT card | 6.48 / 6.56 / 6.61 | 6.24 / 6.27 / 6.30 |
| A, B and D together | Pro, NextUI, exFAT card | 6.48 / 6.56 / 6.61 | 6.28 / 6.54 / 6.15, then 6.21 |

With a card, A and B change nothing for NextUI. The patches here include the
fixes from a code review of A, B and D.

## What each change does

- **A.** With no card, NextUI's `runtrimui.sh` waits 3 s for one, and then
  TrimUI's launcher waits 3 s more. The pak's block in `/etc/init.d/runtrimui`
  marks the slot empty when there is no `/dev/mmcblk1` and the slot's
  card-detect GPIO reads high. In debugfs `gpio` that GPIO is labelled `cd`.
  It is gpio-166 on both models and reads `lo` with a card. If debugfs isn't
  mounted yet, the script mounts it privately in `/tmp`. Each launcher skips
  its wait only if the mark is there and `/dev/mmcblk1` still isn't. A card
  inserted during those few seconds of startup is missed, which we accepted.
- **B.** At startup, `cat /sys/devices/platform/soc/usbc0/usb_device` sleeps
  in the kernel until the USB scan thread stops, in `msleep(1000)` steps. The
  stock menu waited 1.05 s for it. B runs it in the background and writes its
  PID to `/tmp/startup-speeder-usb.pid`. MainUI changes the USB mode by running
  `usb_host.sh` or `usb_dock.sh`, and both now wait while that process is
  alive, for at most 10 s. So the startup switch can't undo a later mode
  change.
- **D.** Each boot, procd started about 747 `hotplug-call` shells, one at a
  time, from about 3 s to 13 s. They kept a core busy while NextUI started,
  and procd alone used 2.65 s of CPU. 301 were for `tty` events and 280 for
  `platform` events. Neither subsystem has an `/etc/hotplug.d` directory, so
  those shells did nothing. The overlay copy of `/etc/hotplug.json` drops
  those two execs and keeps the rule for USB serial (`ttyUSB*`, `ttyACM*`).
  Shipping it would need a hash check so it installs only over TrimUI 1.1.1's
  file, because the overlay copy hides any later firmware's rules.

## Tried, no gain

- C, skipping the block hotplug script for eMMC, loop and RAM disks, changed
  nothing on either path.
- The performance CPU governor from the first init script changed nothing.
  MainUI is CPU-bound, but ondemand already raises the clock.
- The camera modules (`vin_v4l2`, `ov5648_mipi`) take 0.1 s to load and find
  no camera, so removing them isn't worth it.
- `check_fs 0` in TrimUI's `/rom` fstab saved 0.03 s.

## The overlay mount

The overlay mount costs about 0.4 s on every frontend. From preinit's
`block extroot` to the mounted overlay takes 0.42 to 0.52 s.

The overlay (`rootfs_data`, ext4, mounted `sync`) is never cleanly unmounted,
because TrimUI, NextUI and spruce all cut power right after a `sync`. So at
every boot e2fsck replays its journal. `iosample` showed the replay as about
11 scattered 4 KB writes, about 50 ms each, from 2.13 to 2.55 s. The same
writes take about 10 ms each at runtime.

Making the journal clean before the power cut doesn't help.

- A freeze and thaw right before the power cut gave the same time.
- A freeze left in place before the power cut (`fsflush -k`) removed the
  replay, but overlayfs then spent 0.24 s recreating `work/work` with
  synchronous writes.

Early-boot synchronous writes are slow no matter which program makes them.
Two options are left. One is to drop the `sync` mount option on the overlay.
The other is to leave the overlay clean at every power-off. Both give up some
crash safety for about 0.3 s.

## Other ideas

- The pak's early SD mount takes 0.27 s on a 119 GB exFAT card, and the
  launcher waits about 0.09 s of it. Mounting the card from preinit and moving
  the mount later would save at most 0.1 s, and needs a `/rom` hook.
