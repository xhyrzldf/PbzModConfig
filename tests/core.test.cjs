"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), os = require("node:os"), path = require("node:path"), cp = require("node:child_process");
const { memoryIO, fileIO, clock } = require("./fixtures.cjs");
const { getHub, publishOptional, SLOT } = require("../provider/Protocol");
const { createStore } = require("../provider/ConfigStore");
const { createJournal, encode, decode } = require("../provider/Journal");
const { descriptor, createDemo } = require("../demo/DemoProvider");
const { createFramework } = require("../src/Framework");
const S = require("../provider/Schema"), L = require("../src/Localization");
function setup(id = "PbzConfigDemo", extra = {}) {
    const io = memoryIO(), time = clock(), events = [], root = {};
    const store = createStore(descriptor(id), createJournal(io, id), { ...time, report: x => events.push(x), ...extra });
    return { io, time, events, root, store, hub: getHub(root, x => events.push(x)) };
}
test("缺席框架仍加载、修改并保存；接入不需要框架文件", () => {
    const x = setup(); publishOptional(x.store, x.root);
    assert.equal(x.store.apply({ enabled: false }).ok, true);
    assert.equal(x.store.flush().ok, true);
    assert.equal(createJournal(x.io, "PbzConfigDemo").load().record.values.enabled, false);
});
for (const order of ["provider-first", "framework-first"]) test("加载顺序 " + order, () => {
    const x = setup(); let framework;
    if (order === "framework-first") framework = createFramework(x.hub);
    x.store.apply({ opacity: 0.55 }); x.hub.publish(x.store);
    framework ||= createFramework(x.hub);
    assert.equal(framework.pages().length, 1);
    assert.equal(framework.pages()[0].values.opacity, 0.55);
    framework.dispose();
});
test("重复注册替换；旧注销和旧行句柄不能影响新实例", () => {
    const x = setup(), first = x.hub.publish(x.store), f = createFramework(x.hub), old = f.pages()[0];
    const next = setup(); x.hub.publish(next.store);
    assert.equal(first.dispose(), false);
    assert.equal(f.pages().length, 1);
    assert.equal(f.edit(old.handle, "enabled", false, old.revision).error, "STALE_PROVIDER");
    x.store.apply({ enabled: false }); assert.equal(f.pages()[0].values.enabled, true); f.dispose();
});
test("目录监听异常隔离，注销幂等", () => {
    const x = setup(); x.hub.subscribeProviders(() => { throw Error("listener"); });
    const r = x.hub.publish(x.store); assert.equal(r.dispose(), true); assert.equal(r.dispose(), false);
    assert(x.events.some(e => e.code === "DIRECTORY_LISTENER_FAILED"));
});
test("协议冲突只阻断注册，业务仍运行", () => {
    const x = setup(); x.root[SLOT] = { protocol: 2 };
    assert(publishOptional(x.store, x.root, e => x.events.push(e)).error);
    assert.equal(x.store.apply({ enabled: false }).ok, true);
});
test("外部修改更新显示；旧修订拒绝；同值不广播", () => {
    const x = setup(); x.hub.publish(x.store); const f = createFramework(x.hub), old = f.pages()[0];
    let count = 0; x.store.subscribe(e => { if (e.origin !== "persistence") count++; });
    x.store.apply({ placement: "left" }); x.store.apply({ placement: "left" });
    assert.equal(count, 1); assert.equal(f.pages()[0].values.placement, "left");
    assert.equal(f.edit(old.handle, "enabled", false, old.revision).error, "REVISION_CONFLICT");
    assert.equal(x.store.read().values.enabled, true); f.dispose();
});
test("批量校验原子性、有限值、范围、步长、稳定枚举", () => {
    const x = setup(), before = x.store.read();
    for (const patch of [{ enabled: false, opacity: NaN }, { opacity: Infinity }, { opacity: 1.1 }, { opacity: 0.234 },
        { placement: "左侧" }, { placement: 0 }, { unknown: true }, { enabled: 1 }]) {
        assert.equal(x.store.apply(patch).ok, false); assert.deepEqual(x.store.read(), before);
    }
    assert.equal(x.store.apply({ opacity: 0.3 }).ok, true);
});
test("去抖合并连续滑动，并有最长保存期限", () => {
    const x = setup(); x.store.flush(); const writes = x.io.writes;
    for (let n = 0; n < 7; n++) { x.store.apply({ opacity: n % 2 ? 0.4 : 0.5 }); x.time.advance(200); }
    assert.equal(x.io.writes, writes); x.time.advance(100);
    assert.equal(x.io.writes, writes + 1); assert.equal(x.store.read().persistence.state, "saved");
});
test("写失败保留内存及 dirty，显式重试成功", () => {
    const x = setup(); x.store.flush(); const old = x.io.files.slice();
    x.io.fail = true; x.store.apply({ enabled: false }); assert.equal(x.store.flush().ok, false);
    assert.deepEqual(x.io.files, old); assert.equal(x.store.read().values.enabled, false);
    assert.equal(x.store.read().persistence.state, "failed");
    assert.equal(x.store.dispose().ok, false); x.io.fail = false; assert.equal(x.store.flush().ok, true);
});
test("断写不能毁掉上一代；冷加载保留损坏原件并要求恢复", () => {
    const x = setup(); x.store.flush(); x.io.torn = true;
    x.store.apply({ enabled: false }); assert.equal(x.store.flush().ok, false);
    const files = x.io.files.slice(), loaded = createJournal(x.io, "PbzConfigDemo").load();
    assert.equal(loaded.record.values.enabled, true); assert.equal(loaded.recovered, true);
    const next = createStore(descriptor(), createJournal(x.io, "PbzConfigDemo"), { ...clock() });
    next.apply({ enabled: false }); assert.equal(next.flush().error, "RECOVERY_REQUIRED"); assert.deepEqual(x.io.files, files);
});
test("两槽全损坏不以默认值覆盖", () => {
    const io = memoryIO(); io.files = ["broken", "broken2"];
    const s = createStore(descriptor(), createJournal(io, "PbzConfigDemo"), { ...clock() });
    assert.equal(s.read().persistence.state, "failed"); assert.equal(s.flush().ok, false); assert.equal(io.writes, 0);
});
test("外部进程改盘有诊断，不静默覆盖当前状态", () => {
    const x = setup(); x.store.flush(); const other = createJournal(x.io, "PbzConfigDemo"); other.load();
    other.save({ schemaVersion: 1, revision: 4, values: { enabled: false, opacity: 0.5, placement: "left" } });
    const saved = x.io.files.slice(); x.store.apply({ opacity: 0.6 }); assert.equal(x.store.flush().ok, false);
    assert.equal(x.store.read().values.opacity, 0.6); assert.deepEqual(x.io.files, saved);
});
test("多个模组各自恢复默认和文件隔离", () => {
    const a = setup("Alpha"), b = setup("Beta"); a.hub.publish(a.store); a.hub.publish(b.store);
    const f = createFramework(a.hub); a.store.apply({ enabled: false }); b.store.apply({ enabled: false });
    const p = f.pages()[0]; assert.equal(f.reset(p.handle, undefined, p.revision).ok, true);
    assert.equal(a.store.read().values.enabled, true); assert.equal(b.store.read().values.enabled, false); f.dispose();
    assert.equal(decode(a.io.files.find(Boolean)).modId, "Alpha"); assert.equal(decode(b.io.files.find(Boolean)).modId, "Beta");
});
test("禁用原因、语言切换和枚举值分离", () => {
    const x = setup(); x.hub.publish(x.store); const f = createFramework(x.hub); x.store.apply({ enabled: false });
    let p = f.pages()[0]; assert.equal(p.rows.find(r => r.key === "opacity").disabledReason, "请先启用演示");
    assert.equal(f.edit(p.handle, "opacity", 0.4, p.revision).error, "DISABLED");
    f.setLanguage("en-US"); p = f.pages()[0]; assert.equal(p.rows.find(r => r.key === "placement").displayValue, "Right");
    assert.equal(p.values.placement, "right"); f.dispose();
});
test("动作不存布尔值；保存按钮使用提供者接口", () => {
    const io = memoryIO(), c = clock(), root = {}; const demo = createDemo(io, { root, ...c });
    const f = createFramework(getHub(root)), p = f.pages()[0];
    assert.equal(f.action(p.handle, "save", p.revision).ok, true);
    assert.equal(Object.hasOwn(demo.store.read().values, "save"), false); f.dispose();
});
test("未知控件跳过且报告；非法默认值拒绝", () => {
    const spec = descriptor(), events = []; spec.entries.push({ key: "future", type: "text" });
    const schema = S.compile(spec, e => events.push(e)); assert(!schema.entries.has("future")); assert.equal(events.length, 1);
    spec.entries[1].defaultValue = 100; assert.throws(() => S.compile(spec), /INVALID_DEFAULT/);
});
test("异常提供者隔离；框架移除不销毁业务仓库", () => {
    const x = setup(), f = createFramework(x.hub, { report: () => {} }); x.hub.publish(x.store);
    x.hub.publish({ ...x.store, modId: "Broken", read() { throw Error("broken"); } });
    assert.equal(f.pages().find(p => p.handle.modId === "Broken").error.operation, "read");
    assert.equal(f.pages().find(p => p.handle.modId === "PbzConfigDemo").values.enabled, true);
    f.dispose(); assert.equal(x.store.apply({ enabled: false }).ok, true); x.store.flush();
});
test("订阅报错不阻断其他订阅与保存", () => {
    const x = setup(); let seen = false;
    x.store.subscribe(() => { throw Error("view failed"); }); x.store.subscribe(() => { seen = true; });
    x.store.apply({ enabled: false }); assert(seen); assert(x.store.flush().ok); assert(x.events.some(e => e.code === "SUBSCRIBER_FAILED"));
});
test("旧格式需显式迁移；缺字段补默认；未知键不静默丢失", () => {
    const io = memoryIO(); io.files[0] = encode({ format: 1, modId: "PbzConfigDemo", generation: 1, schemaVersion: 1, revision: 3, values: { enabled: false } });
    const s = createStore(descriptor(), createJournal(io, "PbzConfigDemo"), { ...clock() });
    assert.equal(s.read().values.opacity, 0.8); assert.equal(s.read().revision, 4); assert.equal(s.flush().ok, true);
    const other = memoryIO(); other.files[0] = encode({ format: 1, modId: "PbzConfigDemo", generation: 1, schemaVersion: 1, revision: 3, values: { obsolete: 1 } });
    const rejected = createStore(descriptor(), createJournal(other, "PbzConfigDemo"), { ...clock() });
    assert.equal(rejected.flush().ok, false); assert.equal(other.writes, 0);
});
test("真实独立进程持久化，卸载界面后仍读取同一份业务值", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "pbz-config-test-"));
    try {
        const child = path.join(__dirname, "child.cjs");
        const run = mode => {
            const result = cp.spawnSync(process.execPath, [child, directory, mode], { encoding: "utf8" });
            assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
        };
        const before = run("write"), after = run("read");
        assert.deepEqual(after, before); assert.equal(after.values.enabled, false); assert.equal(after.values.opacity, 0.45);
    } finally { fs.rmSync(directory, { recursive: true }); }
});
test("文件后端夹具区分缺失和 I/O 失败，不能把失败当首次启动", () => {
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "pbz-config-io-"));
    try {
        const io = fileIO(directory, "Demo"); assert.equal(io.read(0), null);
        const target = path.join(directory, "Demo", "0", "New_CSV.csv"); fs.mkdirSync(target, { recursive: true });
        assert.throws(() => io.read(0));
    } finally { fs.rmSync(directory, { recursive: true }); }
});
test("CSV 校验夹具拒绝篡改、同代冲突、跨模组文件", () => {
    const record = { format: 1, modId: "Demo", generation: 1, schemaVersion: 1, revision: 2, values: { text: "中文,\n" } };
    assert.deepEqual(decode(encode(record)), record); assert.throws(() => decode(encode(record).replace("Demo", "Hack")), /CHECKSUM/);
    const io = memoryIO(); io.files = [encode(record), encode({ ...record, revision: 3 })];
    assert.equal(createJournal(io, "Demo").load().blocked, true);
    assert.equal(createJournal(io, "Other").load().blocked, true);
});
test("语言别名及百分比格式", () => {
    for (const v of ["zh-CN", "zh_Hans", "zhs", "zhHans"]) assert.equal(L.language(v), "zhHans");
    assert.equal(L.format(0.45, { type: "number", format: "P0" }, "en"), "45%");
});
test("坏提供者重复读不会递归触发界面刷新", () => {
    const x = setup(), f = createFramework(x.hub, { report: () => {} });
    let renders = 0;
    f.subscribe(() => { if (++renders > 5) throw Error("render recursion"); f.pages(); });
    x.hub.publish({ ...x.store, read() { throw Error("bad snapshot"); } });
    assert(renders <= 2); f.dispose();
});
test("订阅期间重入注册，必须释放刚返回的旧订阅", () => {
    const x = setup(), replacement = setup(), f = createFramework(x.hub);
    let released = 0;
    x.hub.publish({ ...x.store, subscribe() { x.hub.publish(replacement.store); return () => released++; } });
    assert.equal(released, 1); assert.equal(f.pages().length, 1); f.dispose();
});
test("元数据与快照不向外泄漏可写引用", () => {
    const spec = descriptor(), store = createStore(spec, createJournal(memoryIO(), spec.modId), { ...clock() });
    spec.entries[0].defaultValue = false;
    assert.equal(store.entries[0].defaultValue, true);
    assert.throws(() => { store.read().values.enabled = false; }, TypeError);
});
test("注册遍历期间替换另一提供者，不得复活旧快照", () => {
    const a = setup("Alpha"), old = setup("Beta"), replacement = setup("Beta");
    replacement.store.apply({ enabled: false });
    a.hub.publish({ ...a.store, subscribe(listener) { a.hub.publish(replacement.store); return a.store.subscribe(listener); } });
    a.hub.publish(old.store);
    const f = createFramework(a.hub);
    assert.equal(f.pages().find(p => p.handle.modId === "Beta").values.enabled, false);
    f.dispose();
});
test("订阅失败必须保持错误状态，不能靠后续读取掩盖", () => {
    const x = setup(); x.hub.publish({ ...x.store, subscribe() { throw Error("cannot subscribe"); } });
    const f = createFramework(x.hub, { report: () => {} });
    for (let n = 0; n < 3; n++) assert.equal(f.pages()[0].error.operation, "attach");
    f.dispose();
});
test("不支持的函数条件不能被序列化丢弃，滑条上界必须可达", () => {
    const spec = descriptor(); spec.entries[1].enabledWhen = () => false;
    assert.throws(() => S.compile(spec), /INVALID_CONDITION/);
    delete spec.entries[1].enabledWhen; spec.entries[1].step = 0.03;
    assert.throws(() => S.compile(spec), /INVALID_NUMBER/);
});
test("反复创建和移除配置界面不重新读盘覆盖业务状态", () => {
    const x = setup(); x.hub.publish(x.store); x.store.flush(); let reads = 0;
    const original = x.io.read; x.io.read = function (slot) { reads++; return original.call(this, slot); };
    for (let i = 0; i < 10; i++) {
        const f = createFramework(x.hub); f.pages(); f.pages(); f.dispose();
    }
    assert.equal(reads, 0);
});
test("未提供日志回调时，坏配置仍输出明确诊断", () => {
    const io = memoryIO(); io.files[0] = "bad";
    const warn = console.warn, messages = []; console.warn = value => messages.push(value);
    try {
        createStore(descriptor(), createJournal(io, "PbzConfigDemo"), { ...clock() });
        assert(messages.some(value => value.includes("READ_FAILED")));
    } finally { console.warn = warn; }
});
