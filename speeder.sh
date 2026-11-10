#!/bin/sh
# Startup Speeder Upper: the part that changes the Brick. launch.sh is the UI.
#
#   speeder.sh state        prints: stock, partial, restart, trial, fast, undo, or "unknown <why>"
#                           (restart: installed, and not restarted since)
#   speeder.sh time         prints the last startup time in milliseconds, or nothing
#   speeder.sh install MS [web]  applies every tweak; MS is the stock startup time (or "")
#   speeder.sh keep [MS]    ends the trial and keeps the tweaks
#   speeder.sh remove       puts everything back the way TrimUI shipped it
#   speeder.sh boot         run by NextUI's boot hook on the first startup after install
#   speeder.sh watch        run by the trial timer on the first startup after a web install
#   speeder.sh left         prints the seconds left to answer a web install's trial
#   speeder.sh restart      restarts the Brick
#
# The first startup after an install is a trial. The NextUI pak asks "Keep the
# changes?" on the Brick's screen. The web installer asks on the web page, and
# a timer on the Brick puts everything back if no answer arrives.
#
# Every tweak is checked before and after it is written. The bootloader copies
# that are changed always keep TrimUI's backup copy next to them: a damaged
# primary copy makes the Brick start from the backup, which is never written.

PAK_DIR=$(cd "$(dirname "$0")" && pwd)
PATH="$PATH:/sbin:/usr/sbin"
STATE=/etc/startup-speeder-upper
TMP=/tmp/startup-speeder-upper.$$
LOCK=/tmp/startup-speeder-upper.lock
: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/tg5040}"
: "${SYSTEM_PATH:=$SDCARD_PATH/.system/tg5040}"
HOOK="$USERDATA_PATH/.hooks/boot.d/startup-speeder-upper.sync.sh"
# Without NextUI's folder on the card (or without a card) the log stays off it.
if [ -d "$USERDATA_PATH" ]; then
	LOG="$USERDATA_PATH/logs/Startup Speeder Upper.txt"
else
	LOG=/tmp/startup-speeder-upper.log
fi
DISK=/dev/mmcblk0

log() { echo "$(cut -d' ' -f1 /proc/uptime) $*" >> "$LOG"; }
fail() { log "FAILED: $*"; echo "$*" >&2; return 1; }

model() { sed -n 's/^hwserial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | cut -c1-6; }
MODEL=$(model)
DATA="$PAK_DIR/data/$MODEL"

# ---- small helpers ---------------------------------------------------------

sha() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# u32 little-endian at byte offset $2 of file $1
u32() { hexdump -v -s "$2" -n 4 -e '1/4 "%u"' "$1"; }

# write u32 value $3 little-endian at byte offset $2 of file $1
put_u32() {
	printf "$(printf '\\%03o\\%03o\\%03o\\%03o' $(($3 & 255)) $(($3 >> 8 & 255)) $(($3 >> 16 & 255)) $(($3 >> 24 & 255)))" |
		dd of="$1" bs=1 seek="$2" conv=notrunc 2>/dev/null
}

# Allwinner checksum: sum of all u32 words, with the checksum word at byte $2 counted as the stamp.
sunxi_sum() {
	hexdump -v -n "$3" -e '1/4 "%u\n"' "$1" | awk -v at=$(($2 / 4)) '
		{ w = (NR - 1 == at) ? 1594518585 : $1; s = (s + w) % 4294967296 }
		END { printf "%.0f\n", s }'
}

read_sectors() { dd if=$DISK of="$3" bs=512 skip="$1" count="$2" 2>/dev/null; }

# write file $2 to sector $1 and check it reads back the same
write_sectors() {
	local count=$(( $(wc -c < "$2") / 512 ))
	dd if="$2" of=$DISK bs=512 seek="$1" count="$count" conv=notrunc,fsync 2>/dev/null && sync &&
		read_sectors "$1" "$count" "$TMP/readback" && cmp -s "$2" "$TMP/readback"
}

# ---- boot package: U-Boot, its device tree and firmware ---------------------
# Primary copy at sector 32800 is changed; TrimUI's backup at 24576 never is.

PKG_PRIMARY=32800
PKG_BACKUP=24576

pkg_prepare() {
	[ -f "$DATA/bootpkg.patch" ] || return 1
	local n
	n=$(sed -n 's/^sectors //p' "$DATA/bootpkg.patch")
	PKG_STOCK=$(sed -n 's/^stock //p' "$DATA/bootpkg.patch")
	PKG_TWEAKED=$(sed -n 's/^tweaked //p' "$DATA/bootpkg.patch")
	read_sectors $PKG_BACKUP "$n" "$TMP/pkg.stock" && [ "$(sha "$TMP/pkg.stock")" = "$PKG_STOCK" ] || return 1
	cp "$TMP/pkg.stock" "$TMP/pkg.tweaked"
	grep '^[0-9]' "$DATA/bootpkg.patch" | while read -r off bytes _; do
		printf "$bytes" | dd of="$TMP/pkg.tweaked" bs=1 seek="$off" conv=notrunc 2>/dev/null
	done
	[ "$(sha "$TMP/pkg.tweaked")" = "$PKG_TWEAKED" ] || return 1
	read_sectors $PKG_PRIMARY "$n" "$TMP/pkg.now"
}

pkg_state() {
	case "$(sha "$TMP/pkg.now")" in
		"$PKG_STOCK") echo stock ;;
		"$PKG_TWEAKED") echo tweaked ;;
		*) echo unknown ;;
	esac
}

# Afterwards pkg.now is read again, so pkg_state tells what is on the disk now.
pkg_set() {
	write_sectors $PKG_PRIMARY "$TMP/pkg.$1"
	local rc=$?
	read_sectors $PKG_PRIMARY $(($(wc -c < "$TMP/pkg.stock") / 512)) "$TMP/pkg.now"
	[ $rc = 0 ] && log "boot package: $1"
}

# ---- boot0: the first-stage loader -----------------------------------------
# Byte 0x34 is its serial-output level (8 on stock, 0 is silent). boot0 holds
# unit-specific data written at the factory, so it is not compared with a hash:
# the tweaked copy is TrimUI's backup with that byte and the checksum changed.

B0_PRIMARY=16
B0_BACKUP=256

b0_prepare() {
	read_sectors $B0_BACKUP 128 "$TMP/b0.stock" && read_sectors $B0_PRIMARY 128 "$TMP/b0.now" || return 1
	[ "$(dd if="$TMP/b0.stock" bs=1 skip=4 count=8 2>/dev/null)" = "eGON.BT0" ] || return 1
	[ "$(u32 "$TMP/b0.stock" 16)" = 65536 ] || return 1
	[ "$(sunxi_sum "$TMP/b0.stock" 12 65536)" = "$(u32 "$TMP/b0.stock" 12)" ] || return 1
	[ "$(hexdump -v -s 52 -n 1 -e '1/1 "%u"' "$TMP/b0.stock")" = 8 ] || return 1
	cp "$TMP/b0.stock" "$TMP/b0.tweaked"
	printf '\000' | dd of="$TMP/b0.tweaked" bs=1 seek=52 conv=notrunc 2>/dev/null
	put_u32 "$TMP/b0.tweaked" 12 $(( ($(u32 "$TMP/b0.stock" 12) + 4294967288) % 4294967296 ))
	[ "$(sunxi_sum "$TMP/b0.tweaked" 12 65536)" = "$(u32 "$TMP/b0.tweaked" 12)" ]
}

b0_state() {
	if cmp -s "$TMP/b0.now" "$TMP/b0.stock"; then echo stock
	elif cmp -s "$TMP/b0.now" "$TMP/b0.tweaked"; then echo tweaked
	else echo unknown; fi
}

b0_set() {
	if [ "$1" = tweaked ]; then
		# Only the first sector differs from TrimUI's backup, so only it is written.
		dd if="$TMP/b0.tweaked" of="$TMP/b0.first" bs=512 count=1 2>/dev/null &&
			write_sectors $B0_PRIMARY "$TMP/b0.first"
	else
		write_sectors $B0_PRIMARY "$TMP/b0.stock"
	fi
	local rc=$?
	read_sectors $B0_PRIMARY 128 "$TMP/b0.now"
	[ $rc = 0 ] && log "boot0: $1"
}

# ---- U-Boot environment: kernel arguments -----------------------------------

SETARGS_STOCK='setenv bootargs console=${console} root=${mmc_root} rootwait init=${init} rdinit=${rdinit} loglevel=${loglevel} earlyprintk=${earlyprintk} initcall_debug=${initcall_debug} loglevel=${loglevel} partitions=${partitions} cma=${cma} gpt=1 rotpk_status=${rotpk_status} pstore_blk.blkdev=${blkoops_blkdev} pstore.update_ms=${pstore_update_ms}'
# expedited RCU while the kernel starts, normal RCU after; one RAM disk instead of 16
SETARGS_TWEAKED="$SETARGS_STOCK rcupdate.rcu_expedited=1 rcupdate.rcu_normal_after_boot=1 brd.rd_nr=1"

env_get() { fw_printenv -n "$1" 2>/dev/null; }

env_state() {
	[ "$(env_get boot_normal)" = 'sunxi_flash read 45000000 ${boot_partition};bootm 45000000' ] &&
		[ "$(env_get bootcmd)" = 'run setargs_nand boot_normal' ] &&
		[ "$(env_get boot_partition)" = boot ] || { echo unknown; return; }
	local l a
	l=$(env_get loglevel)
	a=$(env_get setargs_mmc)
	if [ "$l" = 8 ] && [ "$a" = "$SETARGS_STOCK" ]; then echo stock
	elif [ "$l" = 1 ] && [ "$a" = "$SETARGS_TWEAKED" ]; then echo tweaked
	elif { [ "$l" = 8 ] || [ "$l" = 1 ]; } && { [ "$a" = "$SETARGS_STOCK" ] || [ "$a" = "$SETARGS_TWEAKED" ]; }; then echo partial
	else echo unknown; fi
}

env_set() {
	local l a
	if [ "$1" = tweaked ]; then l=1 a=$SETARGS_TWEAKED; else l=8 a=$SETARGS_STOCK; fi
	[ "$(env_get loglevel)" = "$l" ] || fw_setenv loglevel "$l"
	[ "$(env_get setargs_mmc)" = "$a" ] || fw_setenv setargs_mmc "$a"
	[ "$(env_get loglevel)" = "$l" ] && [ "$(env_get setargs_mmc)" = "$a" ] && log "kernel arguments: $1"
}

# ---- GPU driver without its 21 MB of debug data -----------------------------
# The driver loads from TrimUI's read-only system partition before anything
# else is mounted, so the file there is swapped. TrimUI's own file stays next
# to it under another name (a rename, not a copy), so undoing is exact.

GPU=/rom/lib/modules/4.9.191/pvrsrvkm.ko
GPU_KEEP=$GPU.trimui

gpu_pins() {
	case "$MODEL" in
		TG3040) GPU_STOCK=ce2097f29c225e2b95333e15ed651b43552d8faa3a8c2cd41746227942544e12
			GPU_SMALL=ff92cd946170e9525cf1359953e073c154108cc55e08ad62f17be31d4e5c9d73 ;;
		TG4040) GPU_STOCK=5e01c1be38849b2e8bf78d429826c9ce554ab704fffb3bba32c794b78a1a9a8d
			GPU_SMALL=f5d1850623fa50899538e9a6f88d9efdffe9d18254b162c7220e6e79de4bddc2 ;;
	esac
}

# A swap cut short can leave TrimUI's driver under both names, or a stray .new;
# both still count as stock, and gpu_set stock tidies them up.
gpu_state() {
	local now
	now=$(sha $GPU)
	if [ "$now" = "$GPU_STOCK" ] && { [ ! -e $GPU_KEEP ] || [ "$(sha $GPU_KEEP)" = "$GPU_STOCK" ]; }; then echo stock
	elif [ "$now" = "$GPU_SMALL" ] && [ "$(sha $GPU_KEEP)" = "$GPU_STOCK" ]; then echo tweaked
	else echo unknown; fi
}

gpu_leftovers() { [ -e $GPU_KEEP ] || [ -e $GPU.new ]; }
gpu_tidy() { rm -f $GPU_KEEP $GPU.new; }

# Runs $@ with /rom writable, and always makes it read-only again.
with_rom_rw() {
	local rc
	mount -o remount,rw /rom || return 1
	"$@"; rc=$?
	sync
	# The replaced file's cached entry keeps /rom busy until it is dropped.
	echo 2 > /proc/sys/vm/drop_caches
	mount -o remount,ro /rom || log "/rom stays writable until the restart"
	return $rc
}

gpu_swap_in() {
	cp "$DATA/pvrsrvkm.ko" $GPU.new && chmod 0775 $GPU.new && sync &&
		[ "$(sha $GPU.new)" = "$GPU_SMALL" ] &&
		ln -f $GPU $GPU_KEEP && mv -f $GPU.new $GPU
	local rc=$?; rm -f $GPU.new; return $rc
}

gpu_swap_out() { mv -f $GPU_KEEP $GPU; }

gpu_set() {
	case "$1:$(gpu_state)" in
		tweaked:stock) with_rom_rw gpu_swap_in ;;
		stock:tweaked) with_rom_rw gpu_swap_out ;;
	esac
	[ "$1:$(gpu_state)" = stock:stock ] && gpu_leftovers && with_rom_rw gpu_tidy
	[ "$(gpu_state)" = "$1" ] && ! { [ "$1" = stock ] && gpu_leftovers; } && log "GPU driver: $1"
}

# ---- MainUI stand-in ---------------------------------------------------------
# Frontends learn the model with `strings MainUI | grep ^Trimui`, which reads
# TrimUI's 2 MB menu program at every startup. The stand-in is a tiny script
# that starts TrimUI's MainUI, followed by the same model lines.

MAINUI=/usr/trimui/bin/MainUI
MAINUI_UPPER=/overlay/upper$MAINUI
MAINUI_MARK="# Startup Speeder Upper: TrimUI's MainUI is /rom$MAINUI; the lines after exec name the model."

mainui_text() {
	printf '#!/bin/sh\n%s\nexec -a "$0" /rom%s "$@"\n' "$MAINUI_MARK" "$MAINUI"
	strings /rom$MAINUI | grep ^Trimui
}

mainui_state() {
	if [ ! -e $MAINUI_UPPER ]; then echo stock
	elif mainui_text | cmp -s - $MAINUI_UPPER; then echo tweaked
	else echo unknown; fi
}

mainui_set() {
	if [ "$1" = tweaked ] && [ "$(mainui_state)" = stock ]; then
		[ -n "$(strings /rom$MAINUI | grep ^Trimui)" ] || return 1
		mainui_text > $MAINUI.new && chmod 0755 $MAINUI.new && sync && mv -f $MAINUI.new $MAINUI && sync
	elif [ "$1" = stock ] && [ "$(mainui_state)" = tweaked ]; then
		# Takes effect at the next startup; every caller restarts afterwards.
		rm -f $MAINUI_UPPER && sync
	fi
	[ "$(mainui_state)" = "$1" ] && log "MainUI stand-in: $1"
}

# ---- Early SD card mount -------------------------------------------------------
# Stock mounts the card when its hotplug event is handled, about two seconds
# after init starts. A start script mounts it right away instead, the same way
# TrimUI's mount script would, and two marked blocks keep the stock scripts in step.

SD_INIT=/etc/init.d/startup-speeder-sd
SD_LINK=/etc/rc.d/S00startup-speeder-sd
MOUNT_SCRIPT=/etc/hotplug.d/block/10-mount
LAUNCHER=/etc/init.d/runtrimui
BEGIN="# >>> Startup Speeder Upper"
END="# <<< Startup Speeder Upper"

has_block() { grep -q "^[[:space:]]*$BEGIN\$" "$1"; }

# Every opening marker has its closing one, with nothing nested: otherwise
# cutting the blocks out could take TrimUI's own lines with them.
markers_ok() {
	awk -v b="$BEGIN" -v e="$END" '
		{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
		t == b { if (open) bad = 1; open = 1 }
		t == e { if (!open) bad = 1; open = 0 }
		END { exit (bad || open) }' "$1"
}

strip_block() {
	awk -v b="$BEGIN" -v e="$END" '
		{ t = $0; gsub(/^[ \t]+|[ \t]+$/, "", t) }
		t == b { skip = 1; next }
		t == e { skip = 0; next }
		!skip' "$1"
}

# replace file $1 with stdin after a syntax check
replace_file() {
	cat > "$1.new" && chmod 0755 "$1.new" && sh -n "$1.new" && sync && mv -f "$1.new" "$1" && sync
	local rc=$?; rm -f "$1.new"; return $rc
}

sd_state() {
	[ -f $MOUNT_SCRIPT ] && grep -q '^start() {' $LAUNCHER && markers_ok $MOUNT_SCRIPT && markers_ok $LAUNCHER ||
		{ echo unknown; return; }
	if [ ! -e $SD_INIT ] && [ ! -e $SD_LINK ] && ! has_block $MOUNT_SCRIPT && ! has_block $LAUNCHER; then echo stock
	elif cmp -s "$PAK_DIR/sdearly/startup-speeder-sd" $SD_INIT && [ -L $SD_LINK ] &&
		has_block $MOUNT_SCRIPT && has_block $LAUNCHER; then echo tweaked
	else echo partial; fi
}

sd_set() {
	strip_block $MOUNT_SCRIPT > "$TMP/mount" && strip_block $LAUNCHER > "$TMP/launcher" || return 1
	if [ "$1" = tweaked ]; then
		cat "$PAK_DIR/sdearly/mount-guard" "$TMP/mount" | replace_file $MOUNT_SCRIPT &&
			awk -v f="$PAK_DIR/sdearly/launcher-wait" '
				{ print } !done && /^start\(\) \{/ { while ((getline l < f) > 0) print "\t" l; done = 1 }' \
				"$TMP/launcher" | replace_file $LAUNCHER &&
			replace_file $SD_INIT < "$PAK_DIR/sdearly/startup-speeder-sd" &&
			ln -sf ../init.d/startup-speeder-sd $SD_LINK && sync
	else
		rm -f $SD_LINK $SD_INIT && replace_file $MOUNT_SCRIPT < "$TMP/mount" &&
			replace_file $LAUNCHER < "$TMP/launcher"
	fi
	[ "$(sd_state)" = "$1" ] && log "early SD mount: $1"
}

# ---- the whole set ------------------------------------------------------------

# Reads both bootloader copies and builds the stock and tweaked images in $TMP.
# On failure WHY says what is not as expected.
prepare() {
	WHY=""
	rm -rf "$TMP" && mkdir -p "$TMP" "$(dirname "$LOG")" || { WHY="no room in /tmp"; return 1; }
	case "$MODEL" in TG3040|TG4040) ;; *) WHY="model $MODEL"; return 1 ;; esac
	gpu_pins
	pkg_prepare || { WHY="boot package"; return 1; }
	b0_prepare || { WHY="boot0"; return 1; }
}

# One word per part: stock, tweaked, partial or unknown.
parts() { echo "$(pkg_state) $(b0_state) $(env_state) $(gpu_state) $(mainui_state) $(sd_state)"; }

phase() { sed -n 's/^phase=//p' $STATE 2>/dev/null; }
field() { sed -n "s/^$1=//p" $STATE 2>/dev/null; }
boot_id() { cat /proc/sys/kernel/random/boot_id 2>/dev/null; }
# A trial counts from the startup after the install: until then nobody has
# seen the Brick start with the changes.
trial_started() { [ "$(field boot)" != "$(boot_id)" ]; }
# Who asks about a trial: the web page with its timer, or NextUI's boot hook.
# Whatever the other one left behind stands down when it sees this.
web_trial() { [ "$(field via)" = web ]; }
set_state() { # phase, before, after, [boot id of the install, web or pak]
	printf 'phase=%s\nbefore=%s\nafter=%s\nboot=%s\nvia=%s\n' "$1" "$2" "$3" "$4" "$5" > $STATE.new && sync && mv -f $STATE.new $STATE && sync
}

cmd_state() {
	# An undo cut short (say, by a power loss mid-write) can leave a primary
	# bootloader copy damaged; undoing again rewrites it from TrimUI's backup.
	[ "$(phase)" = undo ] && { echo undo; return; }
	prepare || { echo "unknown $WHY"; return; }
	p=$(parts)
	case " $p " in *" unknown "*) echo "unknown $p"; return ;; esac
	case "$(phase)" in
		*) case "$p" in
			"tweaked tweaked tweaked tweaked tweaked tweaked")
				if [ "$(phase)" != trial ]; then echo fast
				elif trial_started; then echo trial
				else echo restart; fi ;;
			"stock stock stock stock stock stock") echo stock ;;
			*) echo partial ;;
		esac ;;
	esac
}

# The time before Linux started, plus when the frontend started: NextUI's
# keymon.elf (it runs for as long as NextUI does), or else TrimUI's MainUI.
# Stays right after a sleep: see src/bootclock.c.
cmd_time() {
	pre=$("$PAK_DIR/bin/bootclock" 2>/dev/null) || return 0
	case "$pre" in "" | *[!0-9]*) return 0 ;; esac
	start=""
	pids=$(pidof keymon.elf) || pids=$(pidof MainUI)
	for pid in $pids; do
		t=$(cut -d' ' -f22 /proc/$pid/stat 2>/dev/null)
		[ -n "$t" ] && { [ -z "$start" ] || [ "$t" -lt "$start" ]; } && start=$t
	done
	[ -n "$start" ] || return 0
	ms=$((pre + start * 10))
	[ $ms -gt 1000 ] && [ $ms -lt 60000 ] && echo $ms
}

apply_all() { # stock or tweaked, in a safe order
	if [ "$1" = tweaked ]; then
		sd_set tweaked && mainui_set tweaked && gpu_set tweaked && env_set tweaked &&
			b0_set tweaked && pkg_set tweaked
	else
		# Each step runs even if an earlier one failed, so as much as possible goes back.
		local rc=0
		[ "$(pkg_state)" = stock ] || pkg_set stock || rc=1
		[ "$(b0_state)" = stock ] || b0_set stock || rc=1
		env_set stock || rc=1
		gpu_set stock || rc=1
		mainui_set stock || rc=1
		[ "$(sd_state)" = stock ] || sd_set stock || rc=1
		return $rc
	fi
}

write_hook() {
	mkdir -p "$(dirname "$HOOK")" && cat > "$HOOK.new" <<EOF && chmod 0755 "$HOOK.new" && mv -f "$HOOK.new" "$HOOK" && sync
#!/bin/sh
# Startup Speeder Upper: after the first faster startup, asks whether to keep it.
# Removes itself once answered. Without an answer, everything goes back to stock.
[ -x "$PAK_DIR/speeder.sh" ] && exec "$PAK_DIR/speeder.sh" boot
EOF
}

# ---- trial timer for web installs ---------------------------------------------
# A web install has nobody to ask on the Brick's screen. A start script runs
# "speeder.sh watch" from a small copy of this tool on the internal storage.
# The web page answers with "keep" or "remove"; with no answer $WATCH_SECS
# seconds after the startup, everything goes back to stock.

KIT=/etc/startup-speeder-upper.d
WATCH_INIT=/etc/init.d/startup-speeder-trial
# Before S99runtrimui, which never returns.
WATCH_LINK=/etc/rc.d/S98startup-speeder-trial
WATCH_SECS=120
WATCH_PID=/tmp/startup-speeder-upper.watch

# An earlier trial's timer may be in place (an install that stopped halfway,
# tried again). A copy that can run is there at every moment: the new one is
# complete before the old one steps aside as $KIT.old, which the start script
# falls back to.
watch_install() {
	rm -rf $KIT.new && mkdir -p "$KIT.new/data/$MODEL" &&
		cp "$PAK_DIR/speeder.sh" $KIT.new/speeder.sh && chmod 0755 $KIT.new/speeder.sh &&
		cp "$DATA/bootpkg.patch" "$KIT.new/data/$MODEL/bootpkg.patch" &&
		cat > $WATCH_INIT.new <<EOF && chmod 0755 $WATCH_INIT.new && sh -n $WATCH_INIT.new && sync || return 1
#!/bin/sh /etc/rc.common
# Startup Speeder Upper: after a web install, puts everything back unless the
# web page says to keep the changes. Removes itself once that is settled.
START=98

start() {
	for kit in $KIT $KIT.old; do
		[ -x \$kit/speeder.sh ] || continue
		\$kit/speeder.sh watch < /dev/null > /dev/null 2>&1 9>&- &
		break
	done
}
EOF
	mv -f $WATCH_INIT.new $WATCH_INIT && ln -sf ../init.d/startup-speeder-trial $WATCH_LINK && sync || return 1
	# After a swap that was cut short, $KIT.old may be the only copy: it
	# stays until the new one is in place.
	if [ -e $KIT ]; then rm -rf $KIT.old && mv $KIT $KIT.old || return 1; fi
	mv $KIT.new $KIT && sync && rm -rf $KIT.old && sync
}

watch_remove() { rm -rf $WATCH_LINK $WATCH_INIT $WATCH_INIT.new $KIT $KIT.new $KIT.old; sync; }
watch_present() { [ -L $WATCH_LINK ] || [ -e $WATCH_INIT ] || [ -e $KIT ] || [ -e $KIT.old ]; }

uptime_s() { cut -d. -f1 /proc/uptime; }

# Only while the timer runs: it starts with the Brick, not with the install.
cmd_left() {
	[ "$(phase)" = trial ] && web_trial && kill -0 "$(cat $WATCH_PID 2>/dev/null)" 2>/dev/null || return 0
	left=$((WATCH_SECS - $(uptime_s)))
	[ $left -gt 0 ] && echo $left || echo 0
}

cmd_watch() {
	case "$(phase)" in
		undo | trial) ;;
		*) watch_remove; return 0 ;;
	esac
	echo $$ > $WATCH_PID
	# An undo that was cut short is finished right away. A trial waits.
	while [ "$(phase)" = trial ] && web_trial && trial_started && [ "$(uptime_s)" -lt $WATCH_SECS ]; do sleep 2; done
	# The page may be answering right now: then it holds the lock, and the
	# phase tells what it did.
	while ! lock; do
		sleep 2
		case "$(phase)" in undo | trial) ;; *) return 0 ;; esac
	done
	case "$(phase)" in
		trial)
			# The pak's trial now: its boot hook asks, and this timer goes.
			web_trial || { watch_remove; return 0; }
			# Installed again since this startup: that trial has its own
			# timer, from its own first startup on.
			trial_started || return 0
			log "no answer $WATCH_SECS s after the startup" ;;
		undo) ;;
		*) return 0 ;;
	esac
	cmd_remove
	case $? in
		0) restart ;;
		# Nothing was tried: the timer stays and tries at the next startup.
		2) return 1 ;;
	esac
	# Retrying a failed undo at every startup could loop, so the timer goes;
	# the installer offers the undo again (the state stays "undo").
	watch_remove
	# With the bootloader back to stock, one restart brings back a screen
	# that the faster startup may have left dark. Never while the timer is
	# still there: it would run, fail and restart again at every startup.
	! watch_present && [ "$(pkg_state):$(b0_state)" = stock:stock ] && restart
}

# ---- one change at a time -----------------------------------------------------

# The kernel holds the lock for as long as descriptor 9 is open, so it goes
# when the holder does, however that ends. Programs started meanwhile must
# not keep it open after the holder has gone: see "9>&-" here and in ui.sh.
LOCKED=""
lock() {
	[ -n "$LOCKED" ] && return 0
	# A failed redirection on exec would end the shell, so try it on "true".
	true >> $LOCK 2>/dev/null || return 1
	exec 9>> $LOCK
	flock -n 9 || { exec 9>&-; return 1; }
	LOCKED=1
}

locked() {
	lock && return 0
	echo "busy: another Startup Speeder Upper is at work" >&2
	return 3
}

cmd_install() {
	prepare || { fail "not a system I know: $WHY"; return 1; }
	case " $(parts) " in *" unknown "*) fail "not a system I know: $(parts)"; return 1 ;; esac
	if [ "$(gpu_state)" = stock ]; then
		free=$(df -k /rom | awk 'NR == 2 { print $4 }')
		[ "${free:-0}" -gt 4096 ] || { fail "/rom has only ${free} KB free"; return 1; }
	fi
	log "install on $MODEL, stock startup ${1:-unknown} ms"
	# The trial starts before the first change: if anything stops halfway,
	# the next startup asks, and no answer puts everything back.
	# In this order, so that a power cut at any point leaves one way of
	# asking that matches the recorded trial: the new way goes in first (it
	# stands down by itself while the state names no trial of its kind), then
	# the state, and only then does an earlier try's other way go.
	via=pak; [ "$2" = web ] && via=web
	{ if [ $via = web ]; then watch_install; else write_hook; fi; } && set_state trial "$1" "" "$(boot_id)" $via || {
		fail "could not write the trial state; putting everything back"
		cmd_remove
		return 1
	}
	if [ $via = web ]; then rm -f "$HOOK"; else watch_remove; fi
	if apply_all tweaked; then
		log "installed: $(parts)"
		return 0
	fi
	fail "install stopped: $(parts); putting everything back"
	cmd_remove
	return 1
}

cmd_keep() {
	[ "$(phase)" = trial ] || { fail "no trial to keep: the changes were already put back"; return 1; }
	trial_started || { fail "restart the Brick first: it has not started with the changes yet"; return 1; }
	# The timer's time is up even when its undo has not managed to start.
	if web_trial && [ "$(uptime_s)" -ge $WATCH_SECS ]; then
		fail "too late: the trial's time is up"; return 1
	fi
	# An install that stopped halfway is not something to keep.
	prepare && [ "$(parts)" = "tweaked tweaked tweaked tweaked tweaked tweaked" ] ||
		{ fail "not every change is in place: $(parts)"; return 1; }
	set_state kept "$(field before)" "$1" || { fail "could not record the answer"; return 1; }
	rm -f "$HOOK"; watch_remove
	log "kept, startup ${1:-unknown} ms"
	return 0
}

# Returns 2 when the Brick could not even be read (no room in /tmp, say):
# nothing was tried, and trying again later may work.
cmd_remove() {
	if [ -f $STATE ] && ! set_state undo "$(field before)" "$(field after)"; then
		fail "could not record the undo"; return 2
	fi
	prepare || { fail "not a system I know: $WHY"; return 2; }
	if apply_all stock; then
		rm -f $STATE "$HOOK"; watch_remove
		# What is left would undo and restart again at every startup.
		if [ -e $STATE ] || [ -e "$HOOK" ] || watch_present; then
			fail "everything is back, but the tool's own files could not be deleted"; return 1
		fi
		log "removed: $(parts)"
		return 0
	fi
	fail "could not put everything back: $(parts)"
	return 1
}

restart() {
	sync
	# NextUI's own restart when it is there, TrimUI's otherwise.
	{ [ -x "$SYSTEM_PATH/bin/reboot_next" ] && "$SYSTEM_PATH/bin/reboot_next"; } || reboot
	exit 0
}

cmd_boot() {
	lock || return 0
	. "$PAK_DIR/ui.sh"
	case "$(phase)" in
		undo) undo_and_restart "Putting everything back..."; return 0 ;;
		trial) ;;
		*)
			# No trial on this Brick: nothing to ask, and nothing to keep this hook for.
			rm -f "$HOOK"; sync; return 0 ;;
	esac
	# The web installer's trial now: its page asks, and this hook goes.
	web_trial && { rm -f "$HOOK"; sync; return 0; }
	# An install that stopped halfway is not something to keep.
	[ "$(cmd_state)" = trial ] || { undo_and_restart "Putting everything back..."; return 0; }
	ms=$(cmd_time)
	# NextUI's install splash may still be drawing; the question has to be seen.
	killall -9 show2.elf 2>/dev/null
	if ask "$(keep_question "$ms")" 15; then
		cmd_keep "$ms"
		return 0
	fi
	undo_and_restart "No worries, putting everything back..."
}

undo_and_restart() {
	busy "$1"
	cmd_remove
	local rc=$?
	unbusy
	[ $rc = 0 ] && restart
	if [ $rc = 2 ]; then
		# Nothing was tried: the hook stays and tries at the next startup.
		tell "Could not put things back just now.\nIt will try again at the next startup." 10
		return 0
	fi
	# Retrying at every startup could loop, so the hook goes; the tool itself
	# offers the undo again (its state stays "undo").
	rm -f "$HOOK"; sync
	tell "Not everything could be put back.\nOpen Startup Speeder Upper to try again." 10
	# With the bootloader back to stock, one restart brings back a screen
	# that the faster startup may have left dark. Never while the hook is
	# still there: it would run, fail and restart again at every startup.
	[ ! -e "$HOOK" ] && [ "$(pkg_state):$(b0_state)" = stock:stock ] && restart
}

trap 'rm -rf "$TMP"' EXIT
# A change runs to its end even when the USB cable that started it is pulled.
# So does a restart: NextUI's stops adb, and with it this command's terminal.
case "$1" in install | keep | remove | restart | watch) trap '' HUP ;; esac

case "$1" in
	state) cmd_state ;;
	time) cmd_time ;;
	install) locked && cmd_install "$2" "$3" ;;
	keep) locked && cmd_keep "$2" ;;
	remove) locked && cmd_remove ;;
	boot) cmd_boot ;;
	watch) cmd_watch ;;
	left) cmd_left ;;
	restart) restart < /dev/null > /dev/null 2>&1 ;;
	field) field "$2" ;;
	*) echo "usage: speeder.sh state|time|install MS [web]|keep [MS]|remove|boot|watch|left|restart" >&2; exit 2 ;;
esac
