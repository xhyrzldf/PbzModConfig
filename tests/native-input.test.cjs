"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const { fixture } = require("./native-input-fixture.cjs");

for (const key of ["Z", "C", "Gamepad_LeftTrigger", "Gamepad_RightTrigger"]) {
    test(`${key} 从真实配置行预览事件放行，原生页签处理器可接收`, t => {
        const f = fixture(); t.after(() => f.dispose());
        assert.equal(f.state.acceptsInput(), true);
        let nativeEvents = 0;
        // Model only event propagation. Actual keyboard/controller bindings remain a game test.
        if (f.key(key) === "unhandled") nativeEvents++;
        assert.equal(nativeEvents, 1, "配置行不能吞掉原生页签切换事件");
        assert.equal(f.key(key, true), "unhandled", "按住时仍交给原生重复策略");
        assert.deepEqual(f.calls, [], "放行不能顺便改值或执行模组动作");
    });
}

test("肩键与返回键继续交给原生设置", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const key of ["Gamepad_LeftShoulder", "Gamepad_RightShoulder", "Gamepad_FaceButton_Right", "Escape"]) {
        assert.equal(f.key(key), "unhandled", key);
    }
    assert.deepEqual(f.calls, []);
});

test("方向键和确认仍由配置行处理，重复确认不再次执行", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const key of ["Gamepad_DPad_Up", "Gamepad_DPad_Down", "Gamepad_DPad_Left", "Gamepad_DPad_Right"]) {
        assert.equal(f.key(key), "handled");
    }
    assert.equal(f.key("Gamepad_FaceButton_Bottom"), "handled");
    assert.equal(f.key("Gamepad_FaceButton_Bottom", true), "handled");
    assert.deepEqual(f.calls.map(call => call[0]), ["move", "move", "step", "step", "action"]);
});

test("键盘方向和确认保持配置操作，页签键不触发改值或动作", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const key of ["Up", "W", "Down", "S", "Left", "A", "Right", "D"]) {
        assert.equal(f.key(key), "handled", key);
    }
    for (const key of ["Enter", "SpaceBar"]) {
        assert.equal(f.key(key), "handled", key);
        assert.equal(f.key(key, true), "handled", `${key} repeat`);
    }
    assert.deepEqual(f.calls.map(call => call[0]), ["move", "move", "move", "move", "step", "step", "step", "step", "action", "action"]);
    f.calls.length = 0;
    for (const key of ["Z", "C"]) {
        f.key(key); f.key(key, true);
    }
    assert.deepEqual(f.calls, [], "切页不能修改当前配置、展开分组或执行动作");
});

test("业务快捷键不会因放行页签键而穿透配置页", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const key of ["M", "F1", "Gamepad_FaceButton_Top"]) assert.equal(f.key(key), "handled");
    assert.deepEqual(f.calls, []);
});

test("扳机模拟轴放行，左摇杆方向仍由配置列表接管", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const key of ["Gamepad_LeftTriggerAxis", "Gamepad_RightTriggerAxis"]) assert.equal(f.analog(key, 0.9), "unhandled");
    assert.equal(f.analog("Gamepad_LeftY", 0.9), "handled");
    assert.equal(f.analog("Gamepad_LeftX", -0.9), "handled");
    assert.deepEqual(f.calls.map(call => call[0]), ["move", "step"]);
});

test("页面覆盖、确认框、隐藏和释放时不截获按键", t => {
    const f = fixture(); t.after(() => f.dispose());
    for (const field of ["covered", "confirming"]) {
        f.state[field] = true;
        assert.equal(f.key("Gamepad_DPad_Down"), "unhandled");
        f.state[field] = false;
    }
    f.state.hide(); assert.equal(f.key("Gamepad_DPad_Down"), "unhandled");
    f.state.show(); f.state.dispose();
    assert.equal(f.key("Gamepad_DPad_Down"), "unhandled");
    assert.deepEqual(f.calls, []);
});
