#!/bin/sh
# Build dist/Startup.Speeder.Upper.pakz: unzip it onto the SD card's root, or
# let NextUI or Pak Store do that. Also builds dist/web, the web installer.
set -eu
cd "$(dirname "$0")/.."

PRESENTER_VERSION=0.14.0
PRESENTER_SHA=264785d9aa3e5f9ac2074c539e480ea1fd6dbe220ee3a52734511aa9ec759830
NAME="Startup Speeder Upper"
PAK="dist/Tools/tg5040/$NAME.pak"

mkdir -p build
presenter=build/minui-presenter-$PRESENTER_VERSION
if [ ! -f "$presenter" ]; then
	curl -fsSL -o "$presenter.part" \
		"https://github.com/josegonzalez/minui-presenter/releases/download/$PRESENTER_VERSION/minui-presenter-tg5040-nextui"
	mv "$presenter.part" "$presenter"
fi
echo "$PRESENTER_SHA  $presenter" | shasum -a 256 -c - > /dev/null

# The boot timer is a tiny static program. CC can name an arm64 compiler
# (the release workflow runs on an arm64 machine); otherwise Docker builds it.
if [ ! -f build/bootclock ] || [ src/bootclock.c -nt build/bootclock ]; then
	if [ -n "${CC:-}" ]; then
		"$CC" -static -Os -s -Wall -Wextra -o build/bootclock src/bootclock.c
	else
		docker run --rm --platform linux/arm64 -v "$PWD":/w -w /w alpine:3.20 \
			sh -c 'apk add -q gcc musl-dev && gcc -static -Os -s -Wall -Wextra -o build/bootclock src/bootclock.c'
	fi
fi

rm -rf dist
mkdir -p "$PAK/bin" "$PAK/sdearly"
cp launch.sh speeder.sh ui.sh pak.json LICENSE THIRD-PARTY.md "$PAK/"
cp sdearly/startup-speeder-sd sdearly/mount-guard sdearly/launcher-wait "$PAK/sdearly/"
cp -R data "$PAK/data"
cp "$presenter" "$PAK/bin/minui-presenter"
cp build/bootclock "$PAK/bin/bootclock"
chmod 0755 "$PAK/launch.sh" "$PAK/speeder.sh" "$PAK/bin/"* "$PAK/sdearly/startup-speeder-sd"

for model in TG3040 TG4040; do
	grep -q '^tweaked ' "$PAK/data/$model/bootpkg.patch"
	[ -s "$PAK/data/$model/pvrsrvkm.ko" ]
done
(cd dist && zip -qrX "Startup.Speeder.Upper.pakz" Tools)
echo "dist/Startup.Speeder.Upper.pakz ($(du -h "dist/Startup.Speeder.Upper.pakz" | cut -f1))"

# The web installer: the page, and the files it sends to a Brick over USB.
# manifest.json lists them with their hashes; the page checks each on arrival.
WEB=dist/web
KIT=$WEB/kit
mkdir -p "$KIT/bin" "$KIT/sdearly"
cp web/index.html web/app.js web/adb.js web/installer.js "$WEB/"
cp speeder.sh "$KIT/"
cp build/bootclock "$KIT/bin/bootclock"
cp sdearly/startup-speeder-sd sdearly/mount-guard sdearly/launcher-wait "$KIT/sdearly/"
cp -R data "$KIT/data"
sum() { shasum -a 256 "$1" | cut -d' ' -f1; }
{
	printf '{\n  "version": "%s",\n  "files": [\n' "$(sed -n 's/.*"version": *"\(.*\)".*/\1/p' pak.json)"
	sep=""
	(cd "$KIT" && find . -type f ! -name manifest.json | sed 's|^\./||' | LC_ALL=C sort) | while read -r f; do
		mode=420
		case "$f" in speeder.sh | bin/* | sdearly/startup-speeder-sd) mode=493 ;; esac
		model=""
		case "$f" in data/*) model=$(echo "$f" | cut -d/ -f2) ;; esac
		printf '%s    {"path": "%s", "mode": %s, "sha256": "%s"' "$sep" "$f" "$mode" "$(sum "$KIT/$f")"
		[ -n "$model" ] && printf ', "model": "%s"' "$model"
		printf '}'
		sep=",
"
	done
	printf '\n  ]\n}\n'
} > "$KIT/manifest.json"
echo "$WEB ($(du -sh "$WEB" | cut -f1))"
