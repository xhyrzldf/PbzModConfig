"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const { fixture } = require("./native-input-fixture.cjs");
const { descriptor } = require("./components-fixture.cjs");
const { memoryIO, clock } = require("./fixtures.cjs");
const { createStore } = require("../provider/ConfigStore");
const { createJournal } = require("../provider/Journal");
const { publishOptional } = require("../provider/Protocol");
const { signatures } = require("../src/LocaleStrings");

function menu(options = {}) {
    const io = options.io || memoryIO();
    let store;
    const f = fixture({ liveActions: true, ...options, createProvider(root) {
        const spec = descriptor(); spec.modId = "PbzMapTracker";
        const shortcut = spec.entries.find(e => e.key === "shortcut");
        shortcut.defaultValue = "F10"; shortcut.enabledWhen = {key: "enabled", equals: true};
        spec.entries.find(e => e.key === "alternate").defaultValue = "Gamepad_DPad_Down";
        store = createStore(spec, createJournal(io, spec.modId), { ...clock(), sounds: {sound: () => () => {}} });
        const registration = publishOptional(store, root);
        return { dispose() { store.dispose(); registration.dispose(); } };
    }});
    f.state.action(f.id); f.state.refresh();
    return Object.assign(f, { io, store, row(key) {
        const id = "PbzMapTracker/" + key, host = f.bind(id), binding = f.state.entries.get(id);
        return { host, binding, value: () => binding.control.selectedText,
            clickValue: () => binding.control.OnButtonBaseClicked.emit(),
            clickName: () => host.OnMouseButtonDown({}, {key: "LeftMouseButton"}) };
    }});
}

test("原生值控件显示键盘和手柄当前绑定，不再向空按钮写文字", t => {
    const f = menu(); t.after(() => f.dispose());
    for (const [key, expected] of [["shortcut", "F10"], ["alternate", "Gamepad_DPad_Down"]]) {
        const r = f.row(key);
        assert.equal(r.value(), expected);
        assert.equal(r.binding.control, r.binding.row.Rotator_SettingValue);
        assert.equal(r.binding.control.interactive, true);
        assert.equal(r.binding.row.Button_Decrease.visibility, 2);
        assert.equal(r.binding.row.Button_Increase.visibility, 2);
        assert.equal(r.binding.row.DecreaseOverlay.attached, false);
        assert.equal(r.binding.row.IncreaseOverlay.attached, false);
        assert.equal(r.binding.control.OptionsScalingSizeBox.attached, false);
    }
    assert.deepEqual(f.reports, f.reports.filter(e => !/FAILED/.test(e.code)));
});

test("Windows Command误报不会写入绑定，Ctrl Alt Shift仍按实际按下记录", t => {
    const heldKeys = ["LeftCommand", "RightCommand"];
    const f = menu({heldKeys}); t.after(() => f.dispose());
    for (const [held, key, expected] of [[[], "F8", "F8"], [["LeftControl"], "K", "Ctrl+K"],
        [["RightAlt", "LeftShift"], "P", "Alt+Shift+P"]]) {
        heldKeys.splice(0, heldKeys.length, "LeftCommand", "RightCommand", ...held);
        f.row("shortcut").clickValue();
        f.row("shortcut").host.OnPreviewKeyDown({}, {key});
        assert.equal(f.store.read().values.shortcut, expected);
        f.row("shortcut").host.OnKeyUp({}, {key});
    }
});

test("展开收起行的箭头及下划线不随原生选中状态重新出现", t => {
    const f = menu(); t.after(() => f.dispose());
    const r = f.row("@title");
    r.host.BP_OnItemSelectionChanged(true);
    r.binding.refresh(f.state.models.get(r.binding.item));
    for (const node of [r.binding.row.DecreaseOverlay, r.binding.row.IncreaseOverlay, r.binding.control.OptionsScalingSizeBox]) {
        node.SetVisibility(0); // Native selection/option callbacks may show them.
        assert.equal(node.attached, false, "decorations must stay outside the live widget tree");
    }
});

test("点击设置名称也进入录入，输入新键后显示并持久化，重开菜单仍一致", () => {
    const f = menu(), io = f.io;
    try {
        assert.equal(f.row("shortcut").clickName(), "handled");
        assert.equal(f.state.editors.capturing, true);
        const capture = f.row("shortcut");
        assert.equal(capture.value(), f.state.word("pressKey"));
        assert.equal(capture.host.OnPreviewKeyDown({}, {key: "F8"}), "handled");
        assert.equal(f.state.editors.capturing, false);
        assert.equal(f.store.read().values.shortcut, "F8");
        assert.equal(f.row("shortcut").value(), "F8");
        f.store.flush();
    } finally { f.dispose(); }
    const reopened = menu({io});
    try { assert.equal(reopened.row("shortcut").value(), "F8"); }
    finally { reopened.dispose(); }
});

test("点击值可录入，取消和清除整行点击可达，空绑定显示本地化文本", t => {
    const f = menu(); t.after(() => f.dispose());
    const old = f.row("shortcut"); old.clickValue();
    assert.equal(f.state.editors.capturing, true);
    assert.equal(f.store.read().values.shortcut, "F10", "the opening click is not a captured binding");
    assert.equal(f.row("shortcut/@cancel").clickName(), "handled");
    assert.equal(f.state.editors.capturing, false);
    assert.equal(f.row("shortcut").value(), "F10");
    f.row("shortcut").clickValue();
    assert.equal(f.row("shortcut/@clear").clickName(), "handled");
    assert.equal(f.state.editors.capturing, false);
    assert.equal(f.store.read().values.shortcut, "");
    assert.equal(f.row("shortcut").value(), f.state.word("unbound"));
    // A delegate retained from a released row must no longer start capture.
    old.clickValue(); assert.equal(f.state.editors.capturing, false);
});

test("动作值支持七种语言，禁用或遮挡设置页时点击不进入录入", t => {
    for (const locale of ["zhHans", "en", "zhHant", "ko", "ru", "es-ES", "es-419"]) {
        const f = menu({engineLanguage: locale, menuText: signatures[locale]}); t.after(() => f.dispose());
        assert.equal(f.state.locale, locale);
        f.row("shortcut").clickValue();
        const capture = f.row("shortcut");
        assert.equal(capture.value(), f.state.word("pressKey"));
        capture.host.OnPreviewKeyDown({}, {key: "Escape"});
        const r = f.row("shortcut");
        assert.equal(r.value(), "F10");
        f.state.covered = true;
        assert.equal(r.clickName(), "unhandled"); r.clickValue();
        assert.equal(f.state.editors.capturing, false);
        f.state.covered = false; f.store.apply({enabled: false}); f.state.refresh();
        const disabled = f.row("shortcut");
        assert.equal(disabled.binding.control.enabled, false);
        assert.equal(disabled.clickName(), "unhandled"); disabled.clickValue();
        assert.equal(f.state.editors.capturing, false);
    }
});

test("动作行更换值控件后，手柄确认仍能录入手柄按键", t => {
    const f = menu(); t.after(() => f.dispose());
    const r = f.row("alternate");
    r.host.OnPreviewKeyDown({}, {key: "Gamepad_FaceButton_Bottom"});
    assert.equal(f.state.editors.capturing, true);
    f.row("alternate").host.OnPreviewKeyDown({}, {key: "Gamepad_DPad_Up"});
    assert.equal(f.store.read().values.alternate, "Gamepad_DPad_Up");
    assert.equal(f.row("alternate").value(), "Gamepad_DPad_Up");
});
