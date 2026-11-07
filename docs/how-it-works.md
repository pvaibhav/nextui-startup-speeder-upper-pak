# How it works

A stock Brick spends most of its 15-second startup waiting. Each tweak below
was measured on its own on a Brick Pro and Hammer, and kept only if it saved
time and broke nothing.

## The tweaks

| Part | Change | Saves |
|---|---|---|
| U-Boot | `burn_key` 1 to 0: no wait for a computer's flashing tool | 0.8 s, 3.3 s with a computer attached |
| U-Boot | `debug_mode` 8 to 0, `pr_msg` check skipped: no serial output | 0.4 s |
| U-Boot | Panel reset pulse 120 to 10 ms. Wait after display-on 50 to 10 ms (jd9168) or 250 to 10 ms (gh7003) | 0.3 to 0.5 s |
| boot0 | Header byte 0x34, 8 to 0: no serial output | 0.15 s |
| U-Boot env | `loglevel=1 rcupdate.rcu_expedited=1 rcupdate.rcu_normal_after_boot=1 brd.rd_nr=1` | 2.4 s |
| `/rom` | GPU driver minus 21 MB of debug data | 0.2 s |
| Overlay | `MainUI` replaced by a 200-byte script with the same model lines, for `strings MainUI` | 0.1 s |
| Overlay | SD card mounted when init starts, not on its hotplug event | 1.6 s |

## Safety nets

- **Pinned hashes.** The boot package edits (`data/<model>/bootpkg.patch`,
  from `tools/gen-patches.py`) go onto a copy of TrimUI's backup package. The
  result must match a pinned hash, or nothing gets written. Unknown firmware
  gets left alone.
- **Backups stay stock.** Only the primaries get written: boot0 at sector 16
  and the boot package at 32800. The backups at 256 and 24576 never change.
  A damaged primary makes the Brick boot the backup, so a power cut mid-write
  means a stock startup.
- **Every write gets read back** and compared.
- **Trial first.** Before changing anything, the tool records a trial in
  `/etc/startup-speeder-upper` and adds a boot hook on the SD card. Next
  startup, the hook asks "Keep the changes?" for 15 seconds. Only **A**
  keeps them. Anything else undoes everything and restarts.
- **Exact undo.** The boot package and boot0 come back from TrimUI's backups,
  the env gets TrimUI's values, and TrimUI's GPU driver, parked next to the
  small one as `pvrsrvkm.ko.trimui`, gets renamed back. The overlay files and
  marked script blocks get deleted.

## Measuring the startup

The kernel log starts at 0 when Linux does, after the bootloader has already
burned most of the time. So `bin/bootclock` compares the ARM counter, which
starts at power-on, with Linux's raw clock. The difference is the time before
Linux. NTP adjusts neither clock and both pause during sleep, so the number
holds all day: 6599 ms before a 23-second sleep, 6598 ms after. Add when
NextUI started `keymon.elf`, and that's the startup time.

## What goes where

The tool keeps three things on the SD card:

| Path on the SD card | What it is |
|---|---|
| `Tools/tg5040/Startup Speeder Upper.pak/` | the tool itself |
| `.userdata/tg5040/.hooks/boot.d/startup-speeder-upper.sync.sh` | the "Keep the changes?" question at startup, there only until you answer |
| `.userdata/tg5040/logs/Startup Speeder Upper.txt` | a log of what it changed |

Everything else goes on the Brick's internal storage, so the speed-up stays
even if you swap SD cards:

| Path on the Brick | What it is |
|---|---|
| `/etc/startup-speeder-upper` | whether you're in the trial or kept the changes, plus the before and after times |
| `/etc/init.d/startup-speeder-sd`, `/etc/rc.d/S00startup-speeder-sd` | the script that mounts the SD card early |
| marked blocks in TrimUI's `/etc/hotplug.d/block/10-mount` and `/etc/init.d/runtrimui` | TrimUI's mount code skips a card that's already mounted, and its launcher waits up to 1 second for the card |
| `/usr/trimui/bin/MainUI` | the 200-byte stand-in for TrimUI's menu program |
| `/rom/lib/modules/4.9.191/pvrsrvkm.ko` | the GPU driver without its debug data |
| `/rom/lib/modules/4.9.191/pvrsrvkm.ko.trimui` | TrimUI's original GPU driver, kept for the undo |

The bootloader and kernel settings aren't files. The tool writes them
straight to the primary boot0 and boot package on the internal storage, and
to U-Boot's settings (its environment).
