"use strict";
const fs = require("node:fs");
const path = require("node:path");
function memoryIO() {
    return { files: [null, null], writes: 0, fail: false, torn: false,
        read(slot) { return this.files[slot]; },
        write(slot, text) { this.writes++; if (this.fail) return false; this.files[slot] = this.torn ? text.slice(0, text.length / 2) : text; return true; }
    };
}
function fileIO(directory, modId) {
    const root = path.join(directory, modId);
    return {
        read(slot) {
            try { return fs.readFileSync(path.join(root, String(slot), "New_CSV.csv"), "utf8"); }
            catch (e) { if (e.code === "ENOENT") return null; throw e; }
        },
        write(slot, text) {
            const dir = path.join(root, String(slot)); fs.mkdirSync(dir, { recursive: true });
            const fd = fs.openSync(path.join(dir, "New_CSV.csv"), "w");
            try { fs.writeFileSync(fd, text, "utf8"); fs.fsyncSync(fd); } finally { fs.closeSync(fd); }
            return true;
        }
    };
}
function clock() {
    let now = 0, id = 0;
    const jobs = new Map();
    return { schedule(fn, delay) { const key = ++id; jobs.set(key, { at: now + delay, fn }); return key; },
        cancel(key) { jobs.delete(key); },
        advance(ms) { now += ms; for (const [key, job] of Array.from(jobs)) if (jobs.has(key) && job.at <= now) { jobs.delete(key); job.fn(); } },
        count() { return jobs.size; } };
}
module.exports = { memoryIO, fileIO, clock };
