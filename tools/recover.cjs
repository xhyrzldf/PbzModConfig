"use strict";
// Offline recovery makes a NEW directory; it never replaces source files or installs.
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const { decode, encode } = require("../provider/Journal");
const S = require("../provider/Schema");
function recover(source, output, descriptor) {
    const sourceRoot = fs.realpathSync(source), targetRoot = path.resolve(output);
    if (fs.existsSync(targetRoot)) throw new Error("OUTPUT_EXISTS");
    // Prevent creating a recovery directory inside the source namespace.
    const relative = path.relative(sourceRoot, targetRoot);
    if (relative === "" || (!relative.startsWith(".." + path.sep) && relative !== ".." && !path.isAbsolute(relative))) throw new Error("OUTPUT_INSIDE_SOURCE");
    const schema = S.compile(descriptor), records = [], originals = [], errors = [];
    for (let slot = 0; slot < 2; slot++) {
        const file = path.join(sourceRoot, String(slot), "New_CSV.csv");
        let bytes;
        try { bytes = fs.readFileSync(file); }
        catch (e) { if (e.code === "ENOENT") { errors.push({ slot, error: "MISSING" }); continue; } throw e; }
        originals.push({ slot, bytes, sha256: crypto.createHash("sha256").update(bytes).digest("hex") });
        try {
            const raw = bytes[0] === 0xff && bytes[1] === 0xfe ? bytes.subarray(2).toString("utf16le") : bytes.toString("utf8");
            const record = decode(raw);
            if (record.modId !== descriptor.modId || record.schemaVersion !== descriptor.schemaVersion || Object.keys(S.validatePatch(schema, record.values)).length) throw new Error("SCHEMA_OR_NAMESPACE_MISMATCH");
            records.push(record);
        } catch (e) { errors.push({ slot, error: String(e) }); }
    }
    records.sort((a, b) => b.generation - a.generation);
    if (!records.length) throw new Error("NO_VALID_RECORD: " + JSON.stringify(errors));
    if (records.length === 2 && records[0].generation === records[1].generation && JSON.stringify(records[0]) !== JSON.stringify(records[1])) throw new Error("GENERATION_CONFLICT");
    const record = records[0];
    if (record.revision >= Number.MAX_SAFE_INTEGER || record.generation >= Number.MAX_SAFE_INTEGER - 1) throw new Error("COUNTER_OVERFLOW");
    const repaired = { ...record, revision: record.revision + 1, values: { ...schema.defaults, ...record.values } };
    fs.mkdirSync(targetRoot); fs.mkdirSync(path.join(targetRoot, "originals"));
    for (const original of originals) fs.writeFileSync(path.join(targetRoot, "originals", original.slot + ".csv"), original.bytes, { flag: "wx" });
    for (let slot = 0; slot < 2; slot++) {
        fs.mkdirSync(path.join(targetRoot, String(slot)));
        const serialized = encode({ ...repaired, generation: record.generation + slot + 1 });
        const file = path.join(targetRoot, String(slot), "New_CSV.csv");
        fs.writeFileSync(file, serialized, { flag: "wx" });
        if (JSON.stringify(decode(fs.readFileSync(file, "utf8")).values) !== JSON.stringify(repaired.values)) throw new Error("RECOVERY_READBACK_FAILED");
    }
    const manifest = { modId: descriptor.modId, source: sourceRoot, output: targetRoot, errors,
        backups: originals.map(({ slot, sha256 }) => ({ slot, sha256 })), revision: repaired.revision };
    fs.writeFileSync(path.join(targetRoot, "recovery.json"), JSON.stringify(manifest, null, 2), { flag: "wx" });
    return manifest;
}
if (require.main === module) {
    const [source, output, schema] = process.argv.slice(2);
    if (!source || !output || !schema) throw new Error("用法：node recover.cjs <原模组目录> <新目录> <描述JSON文件>");
    console.log(JSON.stringify(recover(source, output, JSON.parse(fs.readFileSync(schema, "utf8"))), null, 2));
}
module.exports = { recover };
