"use strict";
const fs = require("node:fs"), path = require("node:path"), vm = require("node:vm");
const { createRequire } = require("node:module");
const { getHub } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const { createDemo } = require("../demo/DemoProvider");
const { memoryIO } = require("./fixtures.cjs");

function array(values) {
    return { Num: () => values.length, Get: i => values[i], GetRef: i => values[i],
        Add: value => values.push(value), RemoveAt: i => values.splice(i, 1) };
}
function widget() {
    return { visibility: 0, SetVisibility(value) { this.visibility = value; }, GetVisibility() { return this.visibility; },
        GetClass: () => "FixtureWidget", RemoveFromParent() {}, SetSelected() {}, SetFocus() {},
        SetIsInteractionEnabled() {}, SetIsFocusable() {}, SetIsEnabled() {}, SetButtonText() {} };
}

function fixture(options = {}) {
    const reports = [], root = {}, calls = [];
    // A normal optional provider populates the menu, as a business mod does.
    const provider = createDemo(memoryIO(), { root, modId: "PbzMapTracker" });
    const framework = createFramework(getHub(root), { report: event => reports.push(event) });
    let RowHost;
    const UE = {
        Class: { Load: name => name }, Object: {}, BuiltinText: {},
        GameSettingCollection: { StaticClass: () => "Collection" }, NewObject: () => ({}), NewArray: () => array([]),
        Margin: class { constructor() { this.Left = this.Right = this.Top = this.Bottom = 0; } },
        PBZTabDescriptor: class { constructor() { this.TabText = {}; } },
        EWidgetTickFrequency: { Never: 0 }, EHorizontalAlignment: {HAlign_Fill: 0}, EVerticalAlignment: {}, ETextJustify: {Left: 0, Right: 2},
        KismetInternationalizationLibrary: { GetCurrentLanguage: () => options.engineLanguage || "en" },
        PBZBlueprintFunctionLibrary: { MakeTextByKey: () => options.menuText || "NEW GAME" },
        KismetTextLibrary: { Conv_TextToString: value => value },
        KismetInputLibrary: {
            GetKey: event => ({ KeyName: event.key }), InputEvent_IsRepeat: event => !!event.repeat,
            GetAnalogValue: event => event.value
        },
        WidgetBlueprintLibrary: { Handled: () => "handled", Unhandled: () => "unhandled" }
    };
    const puerts = { blueprint: { tojs: value => value, mixin(type, implementation, config) {
        RowHost = implementation; config.generatedClass = implementation;
    } } };
    const list = Object.assign(widget(), {
        BP_SetListItems() {}, RequestRefresh() {}, BP_SetSelectedItem() {}, BP_ScrollItemIntoView() {}
    });
    const ui = {
        V: { Visible: 0, SelfHitTestInvisible: 1, Collapsed: 2 }, valid: value => !!value,
        asText: value => value, text() {}, replaceControl() {},
        lifetime() {
            const cleanup = [];
            return { live: true, bind() {}, own(fn) { cleanup.push(fn); }, dispose() {
                this.live = false; cleanup.splice(0).forEach(fn => fn());
            } };
        },
        native: () => list,
        widget() { return Object.assign(widget(), { Button_Action: widget(), Text_SettingName: {
            justification: 2, SetJustification(value) { this.justification=value; }, SetVisibility() {},
            Slot: { alignment: 2, SetHorizontalAlignment(value) { this.alignment=value; } }
        } }); },
        mount: () => ({ root: widget(), detailRoot: widget(), external: false })
    };
    const children = [], buttons = new Map();
    const box = { GetChildrenCount: () => children.length, GetChildAt: i => children[i] };
    function addButton(id) {
        const button = Object.assign(widget(), { GetParent: () => box, SetTabLabelInfo() {},
            Slot: { Padding: new UE.Margin(), SetPadding(value) { this.Padding = value; } } });
        children.push(button); buttons.set(id, button); return button;
    }
    addButton("Video");
    const tabs = {
        TabButtonIDs: array(["Video"]), PreregisteredTabInfoArray: array([{ TabId: "Video", IconBrush: {}, SwitchSound: {} }]),
        TabButtonBox: box, TabButtonPadding: new UE.Margin(),
        GetTabButtonBaseByID: id => buttons.get(id), GetTabIdAtIndex: index => [...buttons.keys()][index],
        GetIndexByID: id => [...buttons.keys()].indexOf(id),
        RegisterTab(id) { addButton(id); return true; }, RemoveTab: id => buttons.delete(id), ResetTabSwitchTracking() {}
    };
    const panel = { W_OverlayTabList_C: tabs, SettingCollections: array([{}]), SettingWidget: {},
        ListView_Settings: { SelectionMode: 1 }, Details_Settings: widget(),
        WidgetSwitcher_65: { SetActiveWidget(value) { this.active = value; }, GetActiveWidget() { return this.active; }, SetActiveWidgetIndex() {} } };
    const filename = path.join(__dirname, "../native/NativeMenu.js"), realRequire = createRequire(filename);
    const sandbox = { module: { exports: {} }, require(name) {
        if (name === "./NativeSupport") return { createSupport: () => ui };
        if (name === "./NativeFooter") return { createFooter: () => ({ update() {} }) };
        if (name === "./NativeIcon") return { createIconLoader: () => () => ({}) };
        return realRequire(name); // NativeRows and framework logic are the actual implementations.
    }, setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {} };
    vm.runInNewContext(fs.readFileSync(filename, "utf8"), sandbox, { filename });
    const menu = sandbox.module.exports.createMenu(UE, puerts, framework, event => reports.push(event));
    const state = menu.create(panel);
    panel.CurrentCollection = state.collection; state.show();
    const id = "PbzMapTracker/@title", item = state.byId.get(id);
    const host = new RowHost();
    host.WidgetTree = { RootWidget: { GetChildrenCount: () => 0, AddChild: () => ({}) } };
    host.OnListItemObjectSet(item);
    if (!state.entries.has(id)) throw new Error("Fixture row failed to bind: " + JSON.stringify(reports));
    state.selected = id;
    const originalAction=state.action;
    for (const name of ["move", "step", "action"]) state[name] = (...args) => calls.push([name, ...args]);
    return { state, host, id, calls, reports,
        bindHeader() {
            originalAction(id); state.refresh();
            const header=[...state.models].find(([,m])=>m.type==="header");
            if(!header)throw Error("No provider group header");
            const h=new RowHost(); h.WidgetTree={RootWidget:{GetChildrenCount:()=>0,AddChild:()=>({})}};
            h.OnListItemObjectSet(header[0]);
            return state.entries.get(header[1].id);
        },
        key: (key, repeat = false) => host.OnPreviewKeyDown({}, { key, repeat }),
        analog: (key, value) => host.OnAnalogValueChanged({}, { key, value }),
        dispose() { state.dispose(); provider.dispose(); }
    };
}
module.exports = { fixture };
