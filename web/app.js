// The page: one question at a time on the drawn Brick's screen, the same
// questions the NextUI pak asks on the real one.

import { ADB_FILTER } from "./adb.js";
import { NotABrick, settle } from "./installer.js";

const $ = (id) => document.getElementById(id);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const secs = (ms) => (ms / 1000).toFixed(1);

const KEPT = "Kept. You can unplug your Brick.";
const DONE = "Everything is back the way TrimUI shipped it.\nYou can unplug your Brick.";
const NOT_ALL_BACK = "Not everything could be put back.\nConnect again to try once more.";

let answer = { yes: null, no: null };
let ticker = null;
let brick = null;
let serial = "";

// ---- the screen -------------------------------------------------------------

function show(message, { yes = "", no = "", onYes = null, onNo = null, busy = false, note = "" } = {}) {
	clearInterval(ticker);
	$("message").textContent = message;
	$("glass").classList.toggle("busy", busy);
	$("left").textContent = "";
	$("note").textContent = note;
	$("yes").hidden = !yes;
	$("yes").lastChild.textContent = yes;
	$("no").hidden = !no;
	$("no").lastChild.textContent = no;
	answer = { yes: onYes, no: onNo };
}

const busy = (message, note = "") => show(message, { busy: true, note });
const ask = (message, onYes, onNo, note = "") => show(message, { yes: "YES", no: "NO", onYes, onNo, note });

// A message with OK: afterwards the page is ready for the next Brick.
function say(message, note = "") {
	show(message, { yes: "OK", onYes: start, note });
}

function press(which) {
	const act = answer[which];
	if (!act) return;
	answer = { yes: null, no: null };
	clearInterval(ticker);
	Promise.resolve().then(act).catch(fail);
}

$("yes").addEventListener("click", () => press("yes"));
$("no").addEventListener("click", () => press("no"));
$("key-a").addEventListener("click", () => press("yes"));
$("key-b").addEventListener("click", () => press("no"));
document.addEventListener("keydown", (event) => {
	if (event.metaKey || event.ctrlKey || event.altKey || event.repeat) return;
	if (event.key === "a" || event.key === "A") press("yes");
	if (event.key === "b" || event.key === "B") press("no");
});

// ---- the Brick --------------------------------------------------------------

const params = new URLSearchParams(location.search);
const demo = params.get("demo");
const backend = demo ? demoBackend(demo) : usbBackend();

function usbBackend() {
	let kit = null;
	const loadKit = async () => {
		if (kit) return kit;
		const response = await fetch("kit/manifest.json", { cache: "no-cache" });
		if (!response.ok) throw new Error("could not load the installer's files");
		const manifest = await response.json();
		kit = {
			manifest,
			load: async (path) => {
				const file = await fetch(`kit/${path}`, { cache: "no-cache" });
				if (!file.ok) throw new Error(`could not load ${path}`);
				return new Uint8Array(await file.arrayBuffer());
			},
		};
		return kit;
	};
	return {
		available: Boolean(navigator.usb),
		pick: async () => (await navigator.usb.requestDevice({ filters: [ADB_FILTER] })).serialNumber,
		settle: async (options) => settle(navigator.usb, serial, await loadKit(), options),
	};
}

// ?demo=stock, fast or trial: the page's screens without a Brick.
function demoBackend(first) {
	let state = first;
	const fake = {
		install: async () => { await sleep(1500); state = "trial"; },
		keep: async () => { state = "fast"; },
		remove: async () => { await sleep(1500); state = "stock"; },
		restart: async () => "demo",
		bootId: async () => "demo",
		close: async () => {},
	};
	return {
		available: true,
		pick: async () => "demo",
		settle: async () => {
			await sleep(1200);
			const stock = state === "stock";
			return {
				brick: fake,
				status: {
					state, detail: "", now: stock ? 14900 : 5900, before: stock ? null : 14900,
					after: null, left: state === "trial" ? 100 : null, uptime: 60, boot: "demo",
				},
			};
		},
	};
}

async function drop() {
	const old = brick;
	brick = null;
	if (old) await old.close().catch(() => {});
}

// Connects (again) and shows the screen that fits the Brick's state.
async function look(options = {}, expected = "") {
	await drop();
	let status;
	({ brick, status } = await backend.settle(options));
	if (expected === "stock" && status.state === "stock") return say(DONE);
	await route(status);
}

async function restartAndLook(expected = "") {
	const previousBootId = await brick.restart();
	brick = null;
	await look({ previousBootId }, expected);
}

// ---- the questions ----------------------------------------------------------

function start() {
	drop();
	if (!backend.available) {
		show("This page needs Chrome or Edge.\nSafari and Firefox can't talk to USB devices.");
		return;
	}
	show("Plug your Brick into this computer with a USB cable.", {
		yes: "CONNECT",
		onYes: async () => {
			try {
				serial = await backend.pick();
			} catch (error) {
				if (error.name === "NotFoundError") return start();
				throw error;
			}
			busy("Having a look...");
			await look();
		},
	});
}

function route(status) {
	switch (status.state) {
		case "stock":
		case "partial":
			return offer(status);
		case "fast":
			return fastLane(status);
		case "restart":
			// Installed, but the Brick has not restarted since: the trial starts with that.
			busy("All set. Restarting...", "Keep the cable in.");
			return restartAndLook();
		case "trial":
			return keepQuestion(status);
		case "undo":
			return putBack("Putting everything back...");
		default:
			if (status.detail === "boot package") {
				return say("This Brick runs a TrimUI firmware I don't know,\nso I'm leaving it alone.\n\nIt needs TrimUI's firmware 1.1.1.");
			}
			return say("Something on this Brick was changed by another tool,\nso I'm leaving it alone.", status.detail);
	}
}

function offer(status) {
	let message = "Do you want to make the startup faster?";
	if (status.now) message = `Your Brick took ${secs(status.now)} seconds to start.\n\n${message}`;
	ask(message, async () => {
		busy("Speeding things up...", "Keep the cable in. This takes a few seconds.");
		try {
			await brick.install(status.now);
		} catch (error) {
			if (!brick.connected) throw error;
			const after = await brick.status();
			if (after.state === "stock") return say("That didn't work out, so nothing was changed.", error.message);
			return say("That didn't work out, and not everything could be put back.\nConnect again to put it back.", error.message);
		}
		busy("All set. Restarting...", "Keep the cable in.");
		await restartAndLook();
	}, start);
}

function keepQuestion(status) {
	const message = status.now ? `Started in ${secs(status.now)} sec.\nKeep the changes?` : "Keep the changes?";
	const note = "Does the Brick's own screen look right? If not, press NO. No answer puts everything back.";
	ask(message, async () => {
		try {
			await brick.keep(status.now);
		} catch (error) {
			if (!brick.connected) throw error;
			const after = await brick.status();
			// Kept after all (only its log entry failed).
			if (after.state === "fast") return say(KEPT);
			// The Brick's timer was first, and is putting everything back.
			if (after.state === "undo" || after.state === "partial" || after.state === "stock") return tooLate(status.boot);
			return say("Couldn't keep the changes.\nConnect again to try once more.", error.message);
		}
		say(KEPT);
	}, () => putBack("No worries, putting everything back..."), note);
	if (status.left === null) return;
	let left = status.left;
	const expire = () => {
		clearInterval(ticker);
		answer = { yes: null, no: null };
		tooLate(status.boot).catch(fail);
	};
	if (left <= 0) return expire();
	$("left").textContent = `${left} s left`;
	ticker = setInterval(() => {
		left -= 1;
		$("left").textContent = `${left} s left`;
		if (left <= 0) expire();
	}, 1000);
}

// The Brick's own timer ran out: it puts everything back and restarts.
// trialBoot names the startup the trial ran in, so a Brick that has already
// restarted by now counts as back.
async function tooLate(trialBoot) {
	busy("No answer, so the Brick is putting everything back...", "Keep the cable in.");
	await look({ previousBootId: trialBoot, timeoutMs: 150000 }, "stock");
}

async function putBack(message) {
	busy(message, "Keep the cable in. This takes a few seconds.");
	try {
		await brick.remove();
	} catch (error) {
		if (!brick.connected) throw error;
		return say(NOT_ALL_BACK, error.message);
	}
	await restartAndLook("stock");
}

function fastLane(status) {
	const now = status.now ?? status.after;
	let message = "You're already on the fast lane,\nremove the tweaks?";
	if (now && status.before && status.before > now) {
		message = `Your Brick took ${secs(now)} seconds to start.\nThat's ${secs(status.before - now)} seconds less waiting.\n\n${message}`;
	} else if (now) {
		message = `Your Brick took ${secs(now)} seconds to start.\n\n${message}`;
	}
	ask(message, () => putBack("Back to the slow lane..."), start);
}

function fail(error) {
	console.error(error);
	drop();
	if (error instanceof NotABrick) {
		return say("Sorry, this only works on the\nTrimUI Brick, Brick Hammer and Brick Pro.");
	}
	if (error.name === "SecurityError" || error.name === "NetworkError" || error.name === "InvalidStateError") {
		return say("Couldn't open the Brick's USB connection.\nSee \"If it won't connect\" below.", error.message);
	}
	say("Lost the connection to your Brick.\nCheck the cable and connect again.", error.message);
}

start();
// ?demo=trial&go skips the connect button.
if (demo && params.has("go")) press("yes");
