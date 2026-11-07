#!/bin/sh
# Startup Speeder Upper: one question, two buttons.
PAK_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$PAK_DIR" || exit 1
. ./ui.sh
SPEEDER="$PAK_DIR/speeder.sh"

# What a sped-up startup measures, in whole seconds (Brick Pro and Brick Hammer).
TARGET=6

restart() {
	# NextUI restarts the Brick as soon as this pak exits.
	touch /tmp/reboot
	exit 0
}

case "$(sed -n 's/^hwserial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo | cut -c1-6)" in
	TG3040 | TG4040) ;;
	*)
		say "Sorry, this only works on the\nTrimUI Brick, Brick Hammer and Brick Pro."
		exit 0
		;;
esac

busy "Having a look..."
state=$("$SPEEDER" state)
now=$("$SPEEDER" time)
unbusy

case "$state" in
stock | partial)
	# The question after the first fast startup comes from a NextUI startup hook.
	if [ ! -x "$SYSTEM_PATH/bin/run_hooks.sh" ] || ! grep -q 'run_hooks.sh" boot.d' "$SYSTEM_PATH/paks/MinUI.pak/launch.sh"; then
		say "This needs a newer NextUI.\nPlease update NextUI first."
		exit 0
	fi
	msg="Do you want to make the startup faster?"
	[ -n "$now" ] && msg="Your Brick took $(secs "$now") seconds to start.\nLet's dunk that down to about $TARGET.\n\n$msg"
	ask "$msg" || exit 0
	busy "Speeding things up..."
	if "$SPEEDER" install "$now"; then
		busy "All set. Restarting..."
		restart
	fi
	if [ "$("$SPEEDER" state)" = stock ]; then
		unbusy
		say "That didn't work out, so nothing was changed."
	else
		unbusy
		say "That didn't work out, and not everything could be put back.\nOpen Startup Speeder Upper again to put it back."
	fi
	;;
fast)
	before=$("$SPEEDER" field before)
	[ -n "$now" ] || now=$("$SPEEDER" field after)
	msg="You're already on the fast lane,\nremove the tweaks?"
	if [ -n "$now" ] && [ -n "$before" ] && [ "$before" -gt "$now" ]; then
		msg="Your Brick took $(secs "$now") seconds to start.\nThat's $(secs $((before - now))) seconds less waiting.\n\n$msg"
	elif [ -n "$now" ]; then
		msg="Your Brick took $(secs "$now") seconds to start.\n\n$msg"
	fi
	ask "$msg" || exit 0
	busy "Back to the slow lane..."
	"$SPEEDER" remove && restart
	unbusy
	say "Not everything could be put back.\nOpen Startup Speeder Upper to try again."
	;;
trial)
	# The question normally comes at startup; seeing this screen means it works.
	if ask "Startup has been made faster!\n\nKeep the changes?"; then
		"$SPEEDER" keep "$now"
		exit 0
	fi
	busy "No worries, putting everything back..."
	"$SPEEDER" remove && restart
	unbusy
	say "Not everything could be put back.\nOpen Startup Speeder Upper to try again."
	;;
undo)
	busy "Putting everything back..."
	"$SPEEDER" remove && restart
	unbusy
	say "Not everything could be put back.\nOpen Startup Speeder Upper to try again."
	;;
"unknown boot package")
	say "This Brick runs a TrimUI firmware I don't know,\nso I'm leaving it alone.\n\nIt needs TrimUI's firmware 1.1.1."
	;;
*)
	say "Something on this Brick was changed by another tool,\nso I'm leaving it alone."
	;;
esac
