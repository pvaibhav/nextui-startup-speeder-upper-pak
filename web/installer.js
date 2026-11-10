// What the page does to a Brick, without any page: connect, send the tool to
// the Brick's /tmp, and run speeder.sh there. app.js is the page.

import { Adb } from "./adb.js";

const KIT = "/tmp/startup-speeder-upper-kit";
const MODELS = ["TG3040", "TG4040"];

export class NotABrick extends Error {}

const quote = (text) => `'${String(text).replace(/'/g, `'\\''`)}'`;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export class Brick {
	// device: a USBDevice. kit: { manifest, load(path) -> Uint8Array }.
	static async connect(device, kit) {
		const serial = device.serialNumber;
		const adb = await Adb.open(device);
		try {
			const brick = new Brick(adb, serial);
			await brick.identify();
			await brick.sendKit(kit);
			return brick;
		} catch (error) {
			await adb.close();
			throw error;
		}
	}

	constructor(adb, serial) {
		this.adb = adb;
		this.serial = serial;
		this.model = "";
	}

	get connected() {
		return this.adb.connected;
	}

	async run(command) {
		const result = await this.adb.shell(command);
		if (result.code !== 0) {
			const error = new Error(result.output.split("\n").pop() || `exit code ${result.code}`);
			error.output = result.output;
			throw error;
		}
		return result.output;
	}

	async identify() {
		const serial = await this.run("sed -n 's/^hwserial[[:space:]]*:[[:space:]]*//p' /proc/cpuinfo");
		this.model = serial.slice(0, 6);
		if (!MODELS.includes(this.model)) throw new NotABrick(this.model || "unknown device");
	}

	// Sends the files this model needs, skipping those already there from an
	// earlier visit since the last restart.
	async sendKit(kit) {
		const files = kit.manifest.files.filter((file) => !file.model || file.model === this.model);
		const sums = async () => {
			const list = files.map((file) => quote(file.path)).join(" ");
			const { output } = await this.adb.shell(`cd ${KIT} 2>/dev/null && sha256sum ${list} 2>/dev/null`);
			const have = new Map();
			for (const line of output.split("\n")) {
				const match = line.match(/^([0-9a-f]{64})\s+\*?(.+)$/);
				if (match) have.set(match[2], match[1]);
			}
			return have;
		};
		let have = await sums();
		const missing = files.filter((file) => have.get(file.path) !== file.sha256);
		if (!missing.length) return;
		const dirs = [...new Set(files.map((file) => `${KIT}/${file.path}`.replace(/\/[^/]*$/, "")))];
		await this.run(`mkdir -p ${dirs.map(quote).join(" ")}`);
		for (const file of missing) {
			await this.adb.push(`${KIT}/${file.path}`, await kit.load(file.path), file.mode);
		}
		have = await sums();
		const bad = files.find((file) => have.get(file.path) !== file.sha256);
		if (bad) throw new Error(`${bad.path} did not arrive in one piece`);
	}

	speeder(args) {
		return this.run(`${KIT}/speeder.sh ${args}`);
	}

	// { state, detail, now, before, after, left, uptime, boot }: now, before and
	// after in ms; left and uptime in seconds; boot names this startup.
	async status() {
		const s = `${KIT}/speeder.sh`;
		const output = await this.run(
			`echo "state=$(${s} state)"; echo "now=$(${s} time)"; echo "before=$(${s} field before)"; ` +
			`echo "after=$(${s} field after)"; echo "left=$(${s} left)"; echo "uptime=$(cut -d. -f1 /proc/uptime)"; ` +
			`echo "boot=$(cat /proc/sys/kernel/random/boot_id)"`,
		);
		const got = {};
		for (const line of output.split("\n")) {
			const at = line.indexOf("=");
			if (at > 0) got[line.slice(0, at)] = line.slice(at + 1).trim();
		}
		const number = (text) => (/^\d+$/.test(text || "") ? Number(text) : null);
		const [state, ...detail] = (got.state || "unknown").split(" ");
		return {
			state,
			detail: detail.join(" "),
			now: number(got.now),
			before: number(got.before),
			after: number(got.after),
			left: number(got.left),
			uptime: number(got.uptime),
			boot: got.boot || "",
		};
	}

	install(nowMs) {
		return this.speeder(`install ${quote(nowMs ?? "")} web`);
	}

	keep(nowMs) {
		return this.speeder(`keep ${quote(nowMs ?? "")}`);
	}

	remove() {
		return this.speeder("remove");
	}

	// The Brick goes away in the middle of this, so a lost connection is fine.
	async restart() {
		const bootId = await this.bootId().catch(() => "");
		await this.adb.shell(`${KIT}/speeder.sh restart`).catch(() => {});
		await this.adb.close();
		return bootId;
	}

	bootId() {
		return this.run("cat /proc/sys/kernel/random/boot_id");
	}

	close() {
		return this.adb.close();
	}
}

// TrimUI's own launcher resets the USB port once while the Brick starts, which
// drops the connection. Nothing may be changed on the Brick before that is
// over, and it is over once the frontend runs (its start time is known).
const SETTLE_SECONDS = 45;

// Connects to the Brick with this serial number and waits until it has
// finished starting. Returns { brick, status }. With previousBootId (what
// restart() returned), a Brick that has not restarted yet does not count.
export async function settle(usb, serial, kit, { previousBootId = "", timeoutMs = 90000 } = {}) {
	const deadline = Date.now() + timeoutMs;
	let lastError = new Error("the Brick did not come back");
	let first = true;
	while (Date.now() < deadline) {
		if (!first) await sleep(700);
		first = false;
		const devices = await usb.getDevices().catch(() => []);
		const device = devices.find((d) => d.serialNumber === serial);
		if (!device) continue;
		let brick = null;
		try {
			brick = await Brick.connect(device, kit);
			if (previousBootId && (await brick.bootId()) === previousBootId) {
				await brick.close();
				continue;
			}
			for (;;) {
				const status = await brick.status();
				const starting = status.now === null && status.uptime !== null && status.uptime < SETTLE_SECONDS;
				if (!starting) return { brick, status };
				if (Date.now() >= deadline) throw new Error("the Brick is still starting");
				await sleep(1000);
			}
		} catch (error) {
			lastError = error;
			if (brick) await brick.close().catch(() => {});
		}
	}
	throw lastError;
}
