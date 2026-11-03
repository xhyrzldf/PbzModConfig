"use strict";
const fs = require("node:fs"), path = require("node:path"), vm = require("node:vm");
const { createRequire } = require("node:module");
const { getHub } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const { createDemo } = require("../demo/DemoProvider");
const { memoryIO } = require("./fixtures.cjs");
const { createSupport } = require("../native/NativeSupport");

function array(values) {
    return { Num: () => values.length, Get: i => values[i], GetRef: i => values[i],
        Add: value => values.push(value), RemoveAt: i => values.splice(i, 1) };
}
function delegate() {
    const handlers = new Set();
    return { Add: fn => handlers.add(fn), Remove: fn => handlers.delete(fn), handlerCount: () => handlers.size,
        emit: (...args) => { for (const fn of [...handlers]) fn(...args); } };
}
function widget(type = "FixtureWidget") {
    return { visibility: 0, TickFrequency:1, SetVisibility(value) { this.visibility = value; }, GetVisibility() { return this.visibility; },
        GetClass: () => type, attached: true, RemoveFromParent() { this.attached = false; }, SetSelected() {}, SetFocus() {},
        OnButtonBaseClicked: delegate(), OnRotated: delegate(),
        SetIsInteractionEnabled(value) { this.interactive = value; }, SetIsFocusable() {},
        SetIsEnabled(value) { this.enabled = value; },SetRenderOpacity(value){this.opacity=value;},SetRenderTranslation(value){this.translation=value;},
        OnValueChanged:delegate(),OnMouseCaptureEnd:delegate(),OnControllerCaptureEnd:delegate(),
        // The native Action button has an empty Overlay, not a text widget.
        SetButtonText() {} };
}
function rotator() {
    return Object.assign(widget("FixtureRotator"), {
        OptionsScalingSizeBox: widget(),
        Text: { Font: {}, SetFont(font) { this.Font = font; } },
        PopulateTextLabels(values) { this.labels = Array.from({length: values.Num()}, (_,i) => values.Get(i)); },
        SetSelectedItem(index) { this.index = index; this.selectedText = this.labels[index]; },
        GetSelectedIndex() { return this.index; }
    });
}

function fixture(options = {}) {
    const reports = [], root = {}, calls = [], footerLinks = [];
    const report = event => { reports.push(event); options.report?.(event); };
    // A normal optional provider populates the menu, as a business mod does.
    const provider = options.createProvider ? options.createProvider(root) : createDemo(memoryIO(), { root, modId: "PbzMapTracker" });
    const framework = createFramework(getHub(root), { report });
    let RowHost;
    const UE = {
        Class: { Load: name => name }, Object: {Load:()=>({})}, BuiltinText: {},
        Key: class {constructor(name){this.KeyName=name;}},
        Vector2D: class {constructor(x,y){this.X=x;this.Y=y;}}, Anchors:class{},LinearColor:class{constructor(R,G,B,A){Object.assign(this,{R,G,B,A});}},
        SubsystemBlueprintLibrary:{GetLocalPlayerSubsystem:()=>({IsUIKeyHeld:key=>(options.heldKeys||[]).includes(key.KeyName)})},
        PBZUIActionRouterBase:{StaticClass:()=>({})},
        SGameAIFunctionLibrary:{GetClassDefaultObject:()=>({Font:{FontObject:{},TypefaceFontName:"Regular",LetterSpacing:0}})},
        GameSettingCollection: { StaticClass: () => "Collection" }, NewObject: () => ({}), NewArray: () => array([]),
        Margin: class { constructor() { this.Left = this.Right = this.Top = this.Bottom = 0; } },
        PBZTabDescriptor: class { constructor() { this.TabText = {}; } },
        EWidgetTickFrequency: { Never: 0 }, EHorizontalAlignment: {HAlign_Fill: 0}, EVerticalAlignment: {}, ETextJustify: {Left: 0, Right: 2},
        KismetInternationalizationLibrary: { GetCurrentLanguage: () => options.engineLanguage || "en" },
        PBZBlueprintFunctionLibrary: { MakeTextByKey: () => options.menuText || "NEW GAME" },
        KismetTextLibrary: { Conv_TextToString: value => value },
        KismetSystemLibrary: { LaunchURL: url => calls.push(["url", url]) },
        KismetInputLibrary: {
            GetKey: event => ({ KeyName: event.key }), InputEvent_IsRepeat: event => !!event.repeat,
            PointerEvent_GetEffectingButton:event=>({KeyName:event.key}),
            GetAnalogValue: event => event.value
        },
        WidgetBlueprintLibrary: { Handled: () => "handled", Unhandled: () => "unhandled" }
    };
    const puerts = { blueprint: { tojs: value => value, mixin(type, implementation, config) {
        RowHost = implementation; config.generatedClass = implementation;
    } } };
    const list = Object.assign(widget(), {
        BP_SetListItems() {}, RequestRefresh() {}, BP_SetSelectedItem() {}, BP_ScrollItemIntoView() {},
        BP_OnEntriesGenerated: delegate(), BP_OnEntryReleased: delegate(), BP_OnItemSelectionChanged: delegate(), BP_OnItemScrolledIntoView: delegate()
    });
    const ui = {
        V: { Visible: 0, SelfHitTestInvisible: 1, Collapsed: 2, Hidden:3, HitTestInvisible:4 }, valid: value => !!value,
        asText: value => value, text(label,value) {if(label)label.text=value;}, replaceControl(row,old,fresh) {fresh.parent=old.parent;},
        copySlot() {},
        lifetime() {
            const cleanup = [];
            return { live: true, bind(event, fn) {
                if (!event) return; // Menu-only delegates are outside this fixture.
                event.Add(fn); cleanup.push(() => event.Remove(fn));
            }, own(fn) { cleanup.push(fn); }, dispose() {
                this.live = false; cleanup.splice(0).forEach(fn => fn());
            } };
        },
        native(owner,kind) {
            if(options.realFooter && kind==="Border") {
                const link=Object.assign(widget(),{SetBrushColor(){},SetPadding(){},SetContent(value){this.content=value;}});
                link.OnMouseButtonDownEvent={Bind(fn){link.click=fn;options.footerBind?.(link);},Unbind(){link.click=null;}};
                footerLinks.push(link);return link;
            }
            if(kind==="CommonListView")return list;
            if(kind==="CanvasPanel")return Object.assign(widget(),{AddChildToCanvas(){return{SetAnchors(){},SetAlignment(){},SetPosition(){},SetSize(){}};}});
            return Object.assign(widget(),{SetBrushFromTexture(texture){this.texture=texture;},SetColorAndOpacity(color){this.color=color;},SetMinValue(){},SetMaxValue(){},SetStepSize(){},SetValue(value){this.value=value;},SetDisplayValue(value){this.displayValue=value;}});
        },
        widget(owner, type) {
            if (type === "FixtureRotator") return rotator();
            const decrease=widget(),increase=widget();
            return Object.assign(widget(), { RichText_DynamicDetails:widget(),Box_DetailsExtension:Object.assign(widget(),{AddChild:()=>({})}),
            Button_Action: widget(), Button_Decrease:Object.assign(widget(),{parent:decrease}), Button_Increase:Object.assign(widget(),{parent:increase}),
            DecreaseOverlay:decrease, IncreaseOverlay:increase,
            Slider_SettingValue:widget(),InitCachedTexts(){},CurrentValue:widget(),Text_RightValue:widget(),Text_LeftValue:widget(),Text_SettingValue:widget(),
            SetSelected(selected){this.CurrentValue.SetVisibility(selected?3:1);for(const w of [this.Text_LeftValue,this.Text_RightValue,this.Text_SettingValue])w.SetVisibility(selected?1:3);},
            UpdateCursorTextPosition(){this.cursorUpdates=(this.cursorUpdates||0)+1;this.cursorNormalizedValue=this.Slider_SettingValue.value;},
            Rotator_SettingValue:rotator(), Text_SettingName: {
            justification: 2, SetJustification(value) { this.justification=value; }, SetVisibility() {},
            Slot: { alignment: 2, SetHorizontalAlignment(value) { this.alignment=value; } }
        } }); },
        mount: owner => ({ root: widget(), detailRoot: widget(), external: !!options.externalDetails, originalDetails: owner.Details_Settings })
    };
    if (options.realLifetimes) ui.lifetime = createSupport({}, report).lifetime;
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
    const panel = { W_OverlayTabList_C: tabs, SettingCollections: array([{}]),
        SettingWidget: {OnHostDeactivated: delegate(), OnHostReactivated: delegate()},
        ListView_Settings: { SelectionMode: 1 }, Details_Settings: widget(),
        WidgetSwitcher_65: { SetActiveWidget(value) { this.active = value; }, GetActiveWidget() { return this.active; }, SetActiveWidgetIndex(index) {this.active=index;} } };
    const filename = path.join(__dirname, "../native/NativeMenu.js"), realRequire = createRequire(filename);
    const sandbox = { module: { exports: {} }, require(name) {
        if (name === "./NativeSupport") return { ...realRequire(name), createSupport: () => ui };
        if (name === "./NativeFooter" && !options.realFooter) return { createFooter: () => ({ update() {} }) };
        if (name === "./NativePreview" && !options.realPreview) return { createPreviewPane: () => ({update(){},hide(){},dispose(){}}) }; // Optional real preview for lifecycle integration.
        if (name === "./NativeIcon") return { createIconLoader: () => () => ({}) };
        return realRequire(name); // NativeRows and framework logic are the actual implementations.
    }, setTimeout: () => 1, clearTimeout() {}, setInterval: () => 1, clearInterval() {}, ...options.timerApi };
    vm.runInNewContext(fs.readFileSync(filename, "utf8"), sandbox, { filename });
    const menu = sandbox.module.exports.createMenu(UE, puerts, framework, report,{now:options.now});
    const state = menu.create(panel);
    panel.CurrentCollection = state.collection; state.show();
    const id = "PbzMapTracker/@title", item = state.byId.get(id);
    const host = new RowHost();
    host.WidgetTree = { RootWidget: { GetChildrenCount: () => 0, AddChild: () => ({}) } };
    host.OnListItemObjectSet(item);
    if (!state.entries.has(id)) throw new Error("Fixture row failed to bind: " + JSON.stringify(reports));
    state.selected = id;
    const originalAction=state.action;
    if(!options.liveActions)for (const name of ["move", "step", "action"]) state[name] = (...args) => calls.push([name, ...args]);
    return { state, host, id, calls, reports, ui, panel, menu, framework, UE, footerLinks,
        bindHeader() {
            originalAction(id); state.refresh();
            const header=[...state.models].find(([,m])=>m.type==="header");
            if(!header)throw Error("No provider group header");
            const h=new RowHost(); h.WidgetTree={RootWidget:{GetChildrenCount:()=>0,AddChild:()=>({})}};
            h.OnListItemObjectSet(header[0]);
            return state.entries.get(header[1].id);
        },
        key: (key, repeat = false) => host.OnPreviewKeyDown({}, { key, repeat }),
        bind(id) {
            const h=new RowHost();
            // The actual host is not a CanvasSlot: no anchor/position methods.
            h.WidgetTree={RootWidget:{GetChildrenCount:()=>0,AddChild:()=>({SetHorizontalAlignment(){},SetVerticalAlignment(){},SetPadding(){}})}};
            h.OnListItemObjectSet(state.byId.get(id));state.selected=id;
            if(!state.entries.has(id))throw Error("Row failed: "+JSON.stringify(reports));
            return h;
        },
        analog: (key, value) => host.OnAnalogValueChanged({}, { key, value }),
        dispose() { state.dispose(); provider.dispose(); }
    };
}
module.exports = { fixture };
