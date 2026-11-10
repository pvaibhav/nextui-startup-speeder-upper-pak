// Runs the web installer's own code against a real Brick, from Node instead
// of a browser. Stop the computer's adb first: it holds the USB connection.
//
//   sh tools/build.sh
//   adb kill-server
//   cd <a folder where you ran "npm install usb"> && node <repo>/tools/web-test.mjs status
//
// Commands: status, install, keep, remove, restart, cycle, timeout.
//   cycle    remove if needed, install, restart, keep; ends in the fast state
//   timeout  install, restart, answer nothing; the Brick must undo by itself

import { readFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { ADB_FILTER } from "../web/adb.js";
import { settle } from "../web/installer.js";

const require = createRequire(resolve(process.cwd(), "index.js"));
const { WebUSB } = require("usb");

const kitDir = join(dirname(fileURLToPath(import.meta.url)), "../dist/web/kit");
const kit = {
	manifest: JSON.parse(await readFile(join(kitDir, "manifest.json"), "utf8")),
	load: async (path) => new Uint8Array(await readFile(join(kitDir, path))),
};

const usb = new WebUSB({ allowAllDevices: true });
const started = Date.now();
const say = (...words) => console.log(`[${((Date.now() - started) / 1000).toFixed(1)}s]`, ...words);
const sleep = (ms) => new Promise((done) => setTimeout(done, ms));

function expect(what, got, want) {
	if (got !== want) throw new Error(`${what}: got "${got}", expected "${want}"`);
	say(`ok: ${what} is ${want}`);
}

async function connect() {
	const device = await usb.requestDevice({ filters: [ADB_FILTER] });
	const { brick, status } = await settle(usb, device.serialNumber, kit);
	say(`connected to a ${brick.model}, serial ${brick.serial}: ${JSON.stringify(status)}`);
	return brick;
}

async function restartAndReconnect(brick) {
	const serial = brick.serial;
	const bootId = await brick.restart();
	say("restarting");
	const { brick: back, status } = await settle(usb, serial, kit, { previousBootId: bootId });
	say(`back: ${JSON.stringify(status)}`);
	return back;
}

async function toStock(brick) {
	const status = await brick.status();
	if (status.state === "stock") return brick;
	say(`state is ${status.state}: removing`);
	await brick.remove();
	brick = await restartAndReconnect(brick);
	expect("state after remove", (await brick.status()).state, "stock");
	return brick;
}

async function installAndRestart(brick) {
	const before = await brick.status();
	say(`stock startup: ${before.now} ms`);
	await brick.install(before.now);
	say("installed");
	brick = await restartAndReconnect(brick);
	const status = await brick.status();
	say(JSON.stringify(status));
	expect("state after install", status.state, "trial");
	if (!(status.left > 0)) throw new Error(`no time left to answer: ${status.left}`);
	return [brick, status];
}

const command = process.argv[2] || "status";
let brick = await connect();
try {
	if (command === "status") {
		say(JSON.stringify(await brick.status()));
	} else if (command === "install") {
		await brick.install((await brick.status()).now);
	} else if (command === "keep") {
		await brick.keep((await brick.status()).now);
	} else if (command === "remove") {
		await brick.remove();
	} else if (command === "restart") {
		brick = await restartAndReconnect(brick);
		say(JSON.stringify(await brick.status()));
	} else if (command === "cycle") {
		brick = await toStock(brick);
		let status;
		[brick, status] = await installAndRestart(brick);
		await brick.keep(status.now);
		status = await brick.status();
		say(JSON.stringify(status));
		expect("state after keep", status.state, "fast");
		expect("time left after keep", status.left, null);
	} else if (command === "timeout") {
		brick = await toStock(brick);
		let status;
		[brick, status] = await installAndRestart(brick);
		const serial = brick.serial;
		const bootId = await brick.bootId();
		await brick.close();
		say(`answering nothing for ${status.left} s`);
		await sleep(status.left * 1000);
		({ brick } = await settle(usb, serial, kit, { previousBootId: bootId, timeoutMs: 120000 }));
		say("the Brick restarted by itself");
		expect("state after no answer", (await brick.status()).state, "stock");
	} else {
		throw new Error(`unknown command ${command}`);
	}
} finally {
	await brick.close().catch(() => {});
}
process.exit(0);
