# How Startup Speeder Upper works

The tweaks come from boot-time research on the Brick Hammer and Brick Pro in
the BaseOS project (`brick/research/boot-tweaks-results.md` there). Each one
was measured on its own, and kept only when it saved time without side
effects.

## The tweaks

| Part | Change | Saves (Brick Pro) |
|---|---|---|
| Boot package (U-Boot) | No wait for a PC flashing tool at power-on (`burn_key` 1 → 0) | 0.8 s, or about 3.3 s with a USB cable to a PC |
| Boot package (U-Boot) | No serial output (`debug_mode` 8 → 0), no level-0 messages (`pr_msg` check skipped) | about 0.4 s |
| Boot package (U-Boot) | Panel reset pulse 120 → 10 ms; wait after display-on 50 → 10 ms (jd9168) and 250 → 10 ms (gh7003) | 0.3–0.5 s |
| boot0 | No serial output (header byte 0x34, 8 → 0) | about 0.15 s |
| U-Boot environment | `loglevel=1`; `rcupdate.rcu_expedited=1 rcupdate.rcu_normal_after_boot=1 brd.rd_nr=1` | about 2.4 s |
| System partition | GPU driver without its 21 MB of debug data | about 0.2 s |
| Overlay | `MainUI` stand-in: a 200-byte script with the same model lines, so `strings MainUI` is quick | about 0.1 s |
| Overlay | SD card mounted when init starts, not on its hotplug event | about 1.6 s |

## Safety

- **Pinned inputs.** The boot package edits are a table of byte offsets
  (`data/<model>/bootpkg.patch`, made by `tools/gen-patches.py`). They are
  applied to a copy of TrimUI's backup boot package, and the result must
  match a pinned hash before it is written. A Brick whose backup isn't
  TrimUI's v1.1.1 package is left alone.
- **Backups untouched.** Only the primary boot0 (sector 16) and boot package
  (sector 32800) are written. The backups (sectors 256 and 24576) are never
  written. A primary with a bad checksum makes the Brick start from its backup,
  so a write cut short by a power loss gives a stock startup.
- **Every write is read back** and compared.
- **The trial.** Before the first change, the tool records a trial on the
  Brick (`/etc/startup-speeder-upper`) and puts a startup hook on the SD card
  (`.userdata/tg5040/.hooks/boot.d/startup-speeder-upper.sync.sh`). At the next
  startup the hook asks "Keep the changes?" for 15 seconds, before NextUI's
  menu. Only **A** keeps them. **B**, no answer, or a question that can't be
  shown puts everything back and restarts. An install cut short also ends in
  that question.
- **Undo is exact.** The boot package and boot0 primaries are copied back from
  TrimUI's backups. The environment gets TrimUI's values. TrimUI's GPU driver
  stays on the system partition under another name (`pvrsrvkm.ko.trimui`, a
  rename, not a copy) and is renamed back. The overlay files are deleted, and
  the marked blocks are cut out of TrimUI's two scripts.

## How the startup time is measured

`bin/bootclock` reads the ARM counter, which starts at power-on, next to
Linux's own clocks. The difference is the time before Linux started. Adding
the moment NextUI started `keymon.elf` (from `/proc`) gives the time from
power-on to NextUI. After the Brick has slept, the counter no longer lines up
with Linux's clocks, so the tool then shows no time rather than a wrong one.

## Files

| On the SD card | |
|---|---|
| `Tools/tg5040/Startup Speeder Upper.pak/` | the tool |
| `.userdata/tg5040/.hooks/boot.d/startup-speeder-upper.sync.sh` | only during the trial |
| `.userdata/tg5040/logs/Startup Speeder Upper.txt` | what it changed, and when |

| On the Brick | |
|---|---|
| `/etc/startup-speeder-upper` | trial state and the two startup times |
| `/etc/init.d/startup-speeder-sd`, `/etc/rc.d/S00startup-speeder-sd` | early SD mount |
| marked blocks in `/etc/hotplug.d/block/10-mount`, `/etc/init.d/runtrimui` | keep TrimUI's mount in step |
| `/usr/trimui/bin/MainUI` (overlay) | stand-in |
| `/rom/lib/modules/4.9.191/pvrsrvkm.ko`, `.trimui` | small driver, TrimUI's driver |
