"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path");
const { createEasyCsvIO } = require("../provider/EasyCsvIO");
const { resolveUserRoot } = require("../provider/StorageRoot");
const { encode, decode, createJournal } = require("../provider/Journal");
const { descriptor } = require("../demo/DemoProvider");
const { recover } = require("../tools/recover.cjs");
const StorageProbe = require("../native/StorageProbe");
const { inspect } = require("../native/BoundaryProbe");
const { install } = require("../native/ProbeEntry");
const { fileIO } = require("./fixtures.cjs");
const puerts = { $ref: () => ({ value: undefined }), $unref: value => value.value };
const array = values => ({ Num: () => values.length, Get: index => values[index] });
function ueFixture() {
    const files = new Map(), calls = [];
    const UE = {
        KismetSystemLibrary: { GetPlatformUserDir: () => "C:/Users/Fixture/Documents/" },
        BlueprintPathsLibrary: { FileExists: file => files.has(file) },
        EasyCsv: {
            SaveStringToFile(raw, dir) { calls.push({ operation: "write", dir }); files.set(dir + "/New_CSV.csv", raw); return true; },
            MakeCsvInfoStructFromFile(file, out) {
                assert.equal(typeof file, "string"); assert.equal(typeof out, "object");
                calls.push({ operation: "read", file });
                const raw = files.get(file); if (raw === undefined) return false;
                const cells = raw.trim().split("\n")[1].split(",");
                const key = cells[0] === "config" ? "Config" : cells[0];
                const map = new Map([[key, { StringValues: array(cells.slice(1)) }]]);
                out.value = { CSV_Keys: array([key]), CSV_Map: { Get: key => map.get(key) } };
                return true;
            }
        }
    };
    return { UE, files, calls };
}
const record = { format: 1, modId: "Demo", generation: 1, revision: 0, schemaVersion: 1, values: { enabled: true } };
test("EasyCsv 仅接受字符串路径与 $ref，写后能解析结构化列", () => {
    const x = ueFixture(), io = createEasyCsvIO(x.UE, puerts, "C:/Users/Fixture/AppData/Local/PbzMods/Config", "Demo", file => x.files.has(file));
    assert.equal(io.read(0), null); assert.equal(io.write(0, encode(record)), true);
    assert.deepEqual(decode(io.read(0)), record);
    assert(x.calls.every(c => !(c.file || c.dir).includes("G:")));
});
test("存在但读取失败不能当缺文件；未知存在状态不能返回默认", () => {
    const x = ueFixture(); x.UE.EasyCsv.MakeCsvInfoStructFromFile = () => false;
    const io = createEasyCsvIO(x.UE, puerts, "C:/Config", "Demo", () => true);
    assert.throws(() => io.read(0), /CSV_READ_FAILED/);
    const unknown = createEasyCsvIO(x.UE, puerts, "C:/Config", "Demo", () => undefined);
    assert.throws(() => unknown.read(0), /EXISTENCE_UNKNOWN/);
});
test("保存适配器拒绝存档路径和不明确的根目录", () => {
    const x = ueFixture();
    for (const root of ["relative", "C:/game/SaveGames/config", "C:/Config/../SaveGames", ""]) {
        assert.throws(() => createEasyCsvIO(x.UE, puerts, root, "Demo", () => true), /UNVERIFIED_STORAGE_ROOT/);
    }
});
test("存储探针第二次能读前代；模拟结果仍标同进程而非冷启动通过", () => {
    const x = ueFixture(); let report = StorageProbe.run(x.UE, puerts);
    assert.equal(report.status, "same-process-readback-passed"); assert.equal(report.coldRestartEvidence, null);
    report = StorageProbe.run(x.UE, puerts); assert.equal(report.coldRestartEvidence, 1);
    assert(report.remaining.includes("cold-restart"));
});
test("用户目录 API 不存在时失败关闭，不写游戏目录或猜绝对盘符", () => {
    const x = ueFixture(); delete x.UE.KismetSystemLibrary.GetPlatformUserDir;
    const report = StorageProbe.run(x.UE, puerts); assert.equal(report.status, "failed"); assert.equal(x.calls.length, 0);
});
test("保存根目录来自实测的用户目录接口，拒绝相对路径与存档目录", () => {
    const x = ueFixture(); assert.equal(resolveUserRoot(x.UE), "C:/Users/Fixture/Documents/PbzMods/Config");
    for (const value of ["relative", "C:/SaveGames/", "C:/Users/../game/"]) {
        x.UE.KismetSystemLibrary.GetPlatformUserDir = () => value;
        assert.throws(() => resolveUserRoot(x.UE), /INVALID_USER_DIRECTORY/);
    }
});
test("边界探针只向独立集合注册，不修改原生集合或接收 JS getter", () => {
    let added = 0;
    function Collection() { this.children = []; }
    Collection.prototype.AddSetting = function (child) { added++; this.children.push(child); };
    Collection.prototype.GetChildSettings = function () { return array(this.children); };
    const type = ctor => ({ StaticClass: () => ctor });
    const UE = { NewObject: ctor => new ctor(), GameSettingCollection: type(Collection), GameSettingAction: type(class {}),
        GameSettingValueScalarDynamic: type(class {}), GameSettingValueDiscreteDynamic_Bool: type(class {}) };
    const panel = { SettingCollections: array(["original"]) }, report = inspect(UE, panel);
    assert.equal(added, 1); assert.equal(panel.SettingCollections.Num(), 1);
    assert.equal(report.collectionExperiment.status, "passed-isolated-collection"); assert.equal(report.route, "unselected");
    assert.equal(report.classes.GameSettingValueScalarDynamic.callable.SetDynamicGetter, false);
});
test("反射对象创建失败只报告失败，不声称集合已注册", () => {
    const report = inspect({}, {});
    assert.equal(report.collectionExperiment.status, "failed"); assert.equal(report.route, "unselected");
});
test("探针在 BP_InitWidget 完成后执行一次；多次初始化不叠加", () => {
    class Panel { BP_InitWidget(value) { this.count = (this.count || 0) + 1; return value; } }
    const x = ueFixture(), root = {};
    const warn = console.warn; const reports = [];
    console.warn = value => reports.push(value);
    try {
        const state = install(Panel, x.UE, puerts, root); assert.equal(state.report, null);
        assert.equal(install(Panel, x.UE, puerts, root), state);
        const panel = new Panel(); assert.equal(panel.BP_InitWidget(42), 42); const writes = x.calls.length;
        panel.BP_InitWidget(43); assert.equal(panel.count, 2); assert.equal(x.calls.length, writes);
        assert(reports.some(r => r.includes("PROTOTYPE_PROBE")));
    } finally { console.warn = warn; }
});
test("恢复工具保留原始损坏字节与哈希，只在新目录创建可读副本", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pbz-config-recovery-"));
    try {
        const source = path.join(tmp, "source"), output = path.join(tmp, "output");
        fs.mkdirSync(path.join(source, "0"), { recursive: true }); fs.mkdirSync(path.join(source, "1"));
        const valid = encode({ ...record, modId: "PbzConfigDemo", values: { enabled: false, opacity: 0.45, placement: "left" } });
        fs.writeFileSync(path.join(source, "0", "New_CSV.csv"), valid);
        const corrupt = Buffer.from([0, 0xff, 0x11, 0x33]); fs.writeFileSync(path.join(source, "1", "New_CSV.csv"), corrupt);
        const report = recover(source, output, descriptor()); assert.equal(report.backups.length, 2);
        assert.deepEqual(fs.readFileSync(path.join(source, "1", "New_CSV.csv")), corrupt);
        assert.deepEqual(fs.readFileSync(path.join(output, "originals", "1.csv")), corrupt);
        // fileIO appends namespace, so supply the parent and the output folder name.
        const restored = createJournal(fileIO(tmp, "output"), "PbzConfigDemo").load();
        assert.equal(restored.blocked, false); assert.equal(restored.record.values.enabled, false);
        assert.throws(() => recover(source, output, descriptor()), /OUTPUT_EXISTS/);
        assert.throws(() => recover(source, path.join(source, "nested"), descriptor()), /OUTPUT_INSIDE_SOURCE/);
    } finally { fs.rmSync(tmp, { recursive: true }); }
});
test("无有效配置时恢复工具拒绝猜值，原件保留", () => {
    const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "pbz-config-bad-"));
    try {
        const source = path.join(tmp, "source"); fs.mkdirSync(path.join(source, "0"), { recursive: true });
        fs.writeFileSync(path.join(source, "0", "New_CSV.csv"), "bad");
        assert.throws(() => recover(source, path.join(tmp, "output"), descriptor()), /NO_VALID_RECORD/);
        assert.equal(fs.existsSync(path.join(tmp, "output")), false);
    } finally { fs.rmSync(tmp, { recursive: true }); }
});
