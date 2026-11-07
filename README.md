# Startup Speeder Upper

A NextUI tool that makes the TrimUI Brick, Brick Hammer and Brick Pro start
up more than twice as fast. One button speeds it up, and the same tool puts
it back.

| | Before | After |
|---|---|---|
| Brick Pro, USB cable plugged in | 15.5 s | about 6 s |
| Brick Pro, no cable | about 12.5 s | about 6 s |

Times are from switching on to NextUI starting.

## Install

- **Pak Store:** find Startup Speeder Upper under Miscellaneous Tools.
- **By hand:** copy `Startup.Speeder.Upper.pakz` from the
  [latest release](https://github.com/pvaibhav/nextui-startup-speeder-upper-pak/releases/latest)
  to the root of the SD card, and restart the Brick. NextUI unpacks it.

## Use

1. Open **Tools → Startup Speeder Upper**. It tells you how long your last
   startup took and asks: "Do you want to make the startup faster?"
2. Press **A**. The Brick restarts.
3. After the restart it asks "Keep the changes?". Press **A** to keep them.

If you press **B**, or don't answer within 15 seconds, everything goes back to
how TrimUI shipped it and the Brick restarts again. That also covers a screen
that stays dark after the first fast startup.

To undo it later, open the tool again and press **A** at "remove the tweaks?".

## What it needs

- A TrimUI Brick, Brick Hammer or Brick Pro on TrimUI's firmware 1.1.1. On
  anything else, the tool says so and changes nothing. It does not work on
  the TrimUI Smart Pro.
- NextUI with boot hooks (`.userdata/tg5040/.hooks`).

## What it changes

All of it lives on the Brick's internal storage. The SD card only holds this
tool, plus a small startup hook while it waits for your answer.

- The bootloader doesn't wait for a PC flashing tool, and doesn't print
  messages nobody can see.
- The screen gets switched on with shorter waits.
- Linux prints fewer messages, and starts a little leaner.
- The SD card is mounted as soon as the system starts.
- Smaller copies of two files that are read at every startup: the graphics
  driver (without its debug data) and the file NextUI reads to learn the model.

TrimUI's backup copies of the bootloader are never written. If a changed
copy were ever damaged, the Brick starts from the backup as stock.

How each change works, and how it was measured: [docs/how-it-works.md](docs/how-it-works.md).

## Building

`tools/build.sh` writes `dist/Startup.Speeder.Upper.pakz`. It downloads
minui-presenter and builds the boot timer with Docker. Pushing a tag equal to
the version in `pak.json` publishes a release.

[MIT License](LICENSE). Third-party files: [THIRD-PARTY.md](THIRD-PARTY.md).
