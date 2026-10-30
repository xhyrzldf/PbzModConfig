"use strict";
const { createEasyCsvIO } = require("../provider/EasyCsvIO");
const { createJournal } = require("../provider/Journal");
const { resolveUserRoot } = require("../provider/StorageRoot");
// Candidate reflection APIs are inspected before use. A successful probe is not
// a declaration that they exist on every game version or that read errors mean missing.
function run(UE, puerts) {
    const result = { build: "26266538", kind: "storage-probe", status: "failed", root: null };
    try {
        const paths = UE.BlueprintPathsLibrary;
        const root = resolveUserRoot(UE);
        result.root = root;
        const io = createEasyCsvIO(UE, puerts, root, "PbzModConfigProbe", path => paths.FileExists(path));
        const journal = createJournal(io, "PbzModConfigProbe"), loaded = journal.load();
        result.previous = loaded;
        if (loaded.blocked) throw new Error("PROBE_FILE_RECOVERY_REQUIRED");
        const revision = (loaded.record?.revision || 0) + 1;
        journal.save({ schemaVersion: 1, revision, values: { marker: "中文配置", enabled: true, amount: 0.45 } });
        const restored = createJournal(io, "PbzModConfigProbe").load();
        if (restored.blocked || restored.record?.revision !== revision || restored.record?.values.marker !== "中文配置") throw new Error("PROBE_READBACK_FAILED");
        result.status = "same-process-readback-passed";
        result.revision = revision;
        result.coldRestartEvidence = loaded.record?.revision || null;
        // Missing-file classification and permissions still require a controlled failure experiment.
        result.remaining = ["cold-restart", "missing-vs-denied-read", "denied-write", "torn-write"];
    } catch (e) { result.error = String(e); }
    return result;
}
module.exports = { run };
