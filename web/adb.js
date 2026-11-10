// A small adb client for WebUSB: connect, run a shell command, send a file.
// It speaks to adb daemons that ask for no key, which is what TrimUI ships.

const CNXN = 0x4e584e43, AUTH = 0x48545541, OPEN = 0x4e45504f;
const OKAY = 0x59414b4f, WRTE = 0x45545257, CLSE = 0x45534c43;
const VERSION = 0x01000000, MAX_DATA = 4096;
const SYNC_CHUNK = 60 * 1024;
const HANDSHAKE_MS = 5000, SHELL_MS = 120000, PUSH_MS = 60000;

export const ADB_FILTER = { classCode: 0xff, subclassCode: 0x42, protocolCode: 1 };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function join(chunks) {
	const out = new Uint8Array(chunks.reduce((n, c) => n + c.length, 0));
	let at = 0;
	for (const c of chunks) { out.set(c, at); at += c.length; }
	return out;
}

function u32(n) {
	const b = new Uint8Array(4);
	new DataView(b.buffer).setUint32(0, n, true);
	return b;
}

function findInterface(device) {
	for (const config of device.configurations) {
		for (const iface of config.interfaces) {
			for (const alt of iface.alternates) {
				if (alt.interfaceClass !== 0xff || alt.interfaceSubclass !== 0x42 || alt.interfaceProtocol !== 1) continue;
				const ep = (dir) => alt.endpoints.find((e) => e.type === "bulk" && e.direction === dir);
				if (ep("in") && ep("out")) {
					return { config, iface, alt, epIn: ep("in").endpointNumber, epOut: ep("out").endpointNumber };
				}
			}
		}
	}
	return null;
}

// One open adb stream: bytes in both directions until either side closes it.
class Stream {
	constructor(adb, localId) {
		this.adb = adb;
		this.localId = localId;
		this.remoteId = 0;
		this.chunks = [];
		this.closed = false;
		this.wake = null;
		this.acks = [];
	}

	// Resolves when the Brick acknowledges the next message of this stream.
	// A rejection nobody waits for (the send itself failed) is not an error.
	ack() {
		const acked = new Promise((resolve, reject) => this.acks.push({ resolve, reject }));
		acked.catch(() => {});
		return acked;
	}

	notify() {
		const wake = this.wake;
		this.wake = null;
		if (wake) wake();
	}

	// Next chunk of bytes, or null once the stream is closed and empty.
	async read() {
		for (;;) {
			if (this.chunks.length) return this.chunks.shift();
			if (this.closed) return null;
			this.adb.check();
			await new Promise((resolve) => { this.wake = resolve; });
		}
	}

	async readExactly(n) {
		const parts = [];
		let have = 0;
		while (have < n) {
			const chunk = await this.read();
			if (!chunk) throw new Error("the Brick closed the connection early");
			parts.push(chunk);
			have += chunk.length;
		}
		const all = join(parts);
		if (all.length > n) this.chunks.unshift(all.subarray(n));
		return all.subarray(0, n);
	}

	async readAll() {
		const parts = [];
		for (let chunk; (chunk = await this.read()); ) parts.push(chunk);
		return join(parts);
	}

	async write(bytes) {
		for (let at = 0; at < bytes.length; at += this.adb.maxData) {
			if (this.closed) throw new Error("the Brick closed the connection early");
			const acked = this.ack();
			await this.adb.send(WRTE, this.localId, this.remoteId, bytes.subarray(at, at + this.adb.maxData));
			await acked;
		}
	}

	async close() {
		if (this.closed) return;
		this.closed = true;
		this.adb.streams.delete(this.localId);
		await this.adb.send(CLSE, this.localId, this.remoteId).catch(() => {});
	}

	fail(error) {
		this.closed = true;
		for (const ack of this.acks.splice(0)) ack.reject(error);
		this.notify();
	}
}

export class Adb {
	// device: a USBDevice the person picked. Throws when it cannot be opened.
	static async open(device) {
		const found = findInterface(device);
		if (!found) throw new Error("this device has no adb connection");
		await device.open();
		try {
			if (device.configuration?.configurationValue !== found.config.configurationValue) {
				await device.selectConfiguration(found.config.configurationValue);
			}
			await device.claimInterface(found.iface.interfaceNumber);
			if (found.alt.alternateSetting !== 0) {
				await device.selectAlternateInterface(found.iface.interfaceNumber, found.alt.alternateSetting);
			}
		} catch (error) {
			await device.close().catch(() => {});
			throw error;
		}
		const adb = new Adb(device, found);
		try {
			await adb.within(HANDSHAKE_MS, adb.handshake());
		} catch (error) {
			await adb.close();
			throw error;
		}
		adb.pump();
		return adb;
	}

	constructor(device, found) {
		this.device = device;
		this.iface = found.iface.interfaceNumber;
		this.epIn = found.epIn;
		this.epOut = found.epOut;
		this.maxData = MAX_DATA;
		this.streams = new Map();
		this.nextId = 1;
		this.error = null;
		this.sending = Promise.resolve();
	}

	check() {
		if (this.error) throw this.error;
	}

	// A Brick that stops answering must not leave the page waiting forever:
	// after ms the connection is closed, which also ends what is pending.
	async within(ms, work) {
		let timer;
		const late = new Promise((resolve, reject) => {
			timer = setTimeout(() => {
				const error = new Error("the Brick stopped answering");
				this.close(error);
				reject(error);
			}, ms);
		});
		work.catch(() => {});
		try {
			return await Promise.race([work, late]);
		} finally {
			clearTimeout(timer);
		}
	}

	// Messages go out one at a time, header and data together in order.
	send(command, arg0, arg1, data = new Uint8Array(0)) {
		const header = new DataView(new ArrayBuffer(24));
		let sum = 0;
		for (const byte of data) sum = (sum + byte) >>> 0;
		header.setUint32(0, command, true);
		header.setUint32(4, arg0, true);
		header.setUint32(8, arg1, true);
		header.setUint32(12, data.length, true);
		header.setUint32(16, sum, true);
		header.setUint32(20, (command ^ 0xffffffff) >>> 0, true);
		const run = async () => {
			this.check();
			try {
				await this.transferOut(new Uint8Array(header.buffer));
				if (data.length) await this.transferOut(data);
			} catch (error) {
				// Half a message may have gone out: nothing after it would make sense.
				this.fail(error);
				throw this.error;
			}
		};
		this.sending = this.sending.then(run, run);
		return this.sending;
	}

	async transferOut(bytes) {
		const result = await this.device.transferOut(this.epOut, bytes);
		if (result.status !== "ok") throw new Error(`USB write failed (${result.status})`);
	}

	async transferIn(length) {
		const parts = [];
		let have = 0;
		while (have < length) {
			const result = await this.device.transferIn(this.epIn, length - have);
			if (result.status !== "ok") throw new Error(`USB read failed (${result.status})`);
			const view = result.data;
			parts.push(new Uint8Array(view.buffer, view.byteOffset, view.byteLength));
			have += view.byteLength;
		}
		return join(parts);
	}

	// Null when the 24 bytes are not a message header.
	async receive() {
		const bytes = await this.transferIn(24);
		const header = new DataView(bytes.buffer, bytes.byteOffset, 24);
		const command = header.getUint32(0, true);
		const length = header.getUint32(12, true);
		if (header.getUint32(20, true) !== ((command ^ 0xffffffff) >>> 0) || length > 1 << 20) return null;
		const data = length ? await this.transferIn(length) : new Uint8Array(0);
		return { command, arg0: header.getUint32(4, true), arg1: header.getUint32(8, true), data };
	}

	async handshake() {
		await this.send(CNXN, VERSION, MAX_DATA, encoder.encode("host::\0"));
		// Messages left over from an earlier connection may come first.
		for (let i = 0; i < 64; i++) {
			const message = await this.receive();
			if (!message) continue;
			if (message.command === AUTH) throw new Error("this device asks for an adb key, which TrimUI's system does not");
			if (message.command === CNXN) {
				this.maxData = Math.max(256, Math.min(MAX_DATA, message.arg1));
				this.banner = decoder.decode(message.data);
				return;
			}
		}
		throw new Error("the device did not answer as adb");
	}

	async pump() {
		try {
			for (;;) {
				const message = await this.receive();
				if (!message) throw new Error("the Brick sent something that is not adb");
				const stream = this.streams.get(message.arg1);
				if (!stream) {
					// Data for a stream this side already closed: tell the Brick so.
					if (message.command === WRTE || message.command === OKAY) {
						await this.send(CLSE, message.arg1, message.arg0);
					}
					continue;
				}
				if (message.command === OKAY) {
					stream.remoteId = message.arg0;
					const ack = stream.acks.shift();
					if (ack) ack.resolve();
				} else if (message.command === WRTE) {
					stream.chunks.push(message.data);
					stream.notify();
					await this.send(OKAY, stream.localId, stream.remoteId);
				} else if (message.command === CLSE) {
					this.streams.delete(stream.localId);
					const wasOpen = stream.remoteId !== 0;
					stream.fail(new Error("the Brick closed the connection early"));
					if (wasOpen) await this.send(CLSE, stream.localId, stream.remoteId).catch(() => {});
				}
			}
		} catch (error) {
			this.fail(error);
		}
	}

	fail(error) {
		if (this.error) return;
		this.error = error instanceof Error ? error : new Error(String(error));
		for (const stream of this.streams.values()) stream.fail(this.error);
		this.streams.clear();
	}

	get connected() {
		return !this.error;
	}

	async openStream(service) {
		this.check();
		const stream = new Stream(this, this.nextId++);
		this.streams.set(stream.localId, stream);
		const opened = stream.ack();
		try {
			await this.send(OPEN, stream.localId, 0, encoder.encode(service + "\0"));
			await opened;
		} catch (error) {
			this.streams.delete(stream.localId);
			if (this.error) throw this.error;
			throw new Error(`the Brick refused "${service.split(":")[0]}"`);
		}
		return stream;
	}

	// Runs a command and returns { output, code }. Output has stdout and stderr mixed.
	shell(command, timeoutMs = SHELL_MS) {
		return this.within(timeoutMs, this.runShell(command));
	}

	async runShell(command) {
		const stream = await this.openStream(`shell:{ ${command}\n} 2>&1; echo "<exit:$?>"`);
		const text = decoder.decode(await stream.readAll()).replace(/\r\n/g, "\n");
		this.check();
		const match = text.match(/<exit:(\d+)>\n?$/);
		if (!match) throw new Error("the command was cut short");
		return { output: text.slice(0, match.index).trim(), code: Number(match[1]) };
	}

	// Writes bytes to a file on the Brick (the adb "sync" service).
	push(path, bytes, mode = 0o644) {
		return this.within(PUSH_MS, this.runPush(path, bytes, mode));
	}

	async runPush(path, bytes, mode) {
		const stream = await this.openStream("sync:");
		try {
			const target = encoder.encode(`${path},${0o100000 | mode}`);
			await stream.write(join([encoder.encode("SEND"), u32(target.length), target]));
			for (let at = 0; at < bytes.length; at += SYNC_CHUNK) {
				const chunk = bytes.subarray(at, at + SYNC_CHUNK);
				await stream.write(join([encoder.encode("DATA"), u32(chunk.length), chunk]));
			}
			await stream.write(join([encoder.encode("DONE"), u32(Math.floor(Date.now() / 1000))]));
			const reply = await stream.readExactly(8);
			const word = decoder.decode(reply.subarray(0, 4));
			if (word !== "OKAY") {
				const length = new DataView(reply.buffer, reply.byteOffset + 4, 4).getUint32(0, true);
				const why = word === "FAIL" ? decoder.decode(await stream.readExactly(length)) : "unexpected answer";
				throw new Error(`could not write ${path}: ${why}`);
			}
			await stream.write(join([encoder.encode("QUIT"), u32(0)])).catch(() => {});
		} finally {
			await stream.close();
		}
	}

	async close(why = new Error("disconnected")) {
		this.fail(why);
		await this.device.releaseInterface(this.iface).catch(() => {});
		await this.device.close().catch(() => {});
	}
}
