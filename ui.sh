# Startup Speeder Upper: questions and messages on screen, via minui-presenter.
# Sourced by launch.sh and speeder.sh; PAK_DIR must be set.

PRESENTER="$PAK_DIR/bin/minui-presenter"
BUSY_PID=""

present() { "$PRESENTER" --message-alignment middle "$@" > /dev/null 2>&1; }

# ask MESSAGE [SECONDS]: succeeds only when A is pressed. With SECONDS, the
# answer is "no" when time runs out or the question cannot be shown at all.
ask() {
	local secs=${2:-0} pid guard="" rc
	if [ "$secs" -gt 0 ]; then
		"$PRESENTER" --message-alignment middle --message "$1" --cancel-show --cancel-text NO --confirm-show --confirm-text YES \
			--timeout "$secs" --show-time-left > /dev/null 2>&1 &
		pid=$!
		# A presenter that hangs must not hold up the startup forever.
		(sleep $((secs + 15)); kill $pid) 2> /dev/null &
		guard=$!
	else
		"$PRESENTER" --message-alignment middle --message "$1" --cancel-show --cancel-text NO --confirm-show --confirm-text YES --timeout 0 > /dev/null 2>&1 &
		pid=$!
	fi
	wait $pid; rc=$?
	[ -n "$guard" ] && kill $guard 2> /dev/null
	[ $rc = 0 ]
}

say() { present --message "$1" --confirm-show --confirm-text OK --timeout 0; }

busy() {
	unbusy
	"$PRESENTER" --message-alignment middle --message "$1" --timeout -1 > /dev/null 2>&1 &
	BUSY_PID=$!
}

unbusy() {
	[ -n "$BUSY_PID" ] || return 0
	kill "$BUSY_PID" 2> /dev/null; wait "$BUSY_PID" 2> /dev/null
	BUSY_PID=""
}

# milliseconds -> seconds with one decimal
secs() { awk -v ms="$1" 'BEGIN { printf "%.1f", ms / 1000 }'; }
