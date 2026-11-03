"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const {createSupport} = require("../native/NativeSupport");
const {fixture} = require("./native-input-fixture.cjs");

// A controllable callback queue, not a performance or real-time simulator.
function timers() {
    let id = 0;
    const intervals = new Map(), pending = new Map();
    return {intervals, pending,
        api: {setInterval(fn) {intervals.set(++id, fn); return id;}, clearInterval(id) {intervals.delete(id);},
            setTimeout(fn) {pending.set(++id, fn); return id;}, clearTimeout(id) {pending.delete(id);}},
        poll() {for (const fn of [...intervals.values()]) fn();},
        flush() {let limit=100; while(pending.size) {assert.ok(limit-- > 0, "refresh callback storm");
            const [key, fn]=pending.entries().next().value; pending.delete(key); fn();}}
    };
}

test("callback queue respects cancellation and drains only live work", () => {
    const t=timers(); let calls=0;
    const a=t.api.setInterval(()=>calls++), b=t.api.setTimeout(()=>calls++);
    t.api.clearInterval(a);t.api.clearTimeout(b);t.poll();t.flush();assert.equal(calls,0);
    t.api.setTimeout(()=>calls++);t.flush();t.flush();assert.equal(calls,1);
});

test("destroyed native wrappers are invalid; unrelated native failures stay visible", () => {
    for(const message of ["passing a invalid object", "access a invalid object"]){
        const ui=createSupport({KismetSystemLibrary:{IsValid(){throw Error(message);}}},()=>{});
        assert.equal(ui.valid({}),false);
    }
    const problem=Error("invalid object configuration is not a destroyed wrapper");
    const ui=createSupport({KismetSystemLibrary:{IsValid(){throw problem;}}},()=>{});
    assert.throws(()=>ui.valid({}),e=>e===problem);
});

test("delegate teardown continues after stale owners without hiding unexpected failures", () => {
    const reports=[], ui=createSupport({},e=>reports.push(e)), scope=ui.lifetime();let released=0;
    scope.own(()=>released++);
    scope.own(()=>{throw Error("unexpected delegate failure");});
    scope.own(()=>{throw Error("access a invalid object");});
    scope.dispose();scope.dispose();
    assert.equal(released,1);assert.equal(scope.live,false);
    assert.equal(reports.length,1);assert.match(reports[0].detail,/unexpected delegate failure/);
});

test("a panel destroyed without normal close retires polling, subscriptions and ownership", () => {
    const t=timers(), f=fixture({timerApi:t.api});t.flush();
    const native=createSupport({KismetSystemLibrary:{IsValid(value){if(value===f.panel)throw Error("passing a invalid object");return !!value;}}},e=>f.reports.push(e));
    f.ui.valid=native.valid;
    t.poll();t.flush();
    assert.equal(f.menu.states.size,0);assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
    assert.equal(f.state.entries.size,0);assert.equal(f.state.models.size,0);
    const page=f.framework.pages()[0], row=page.rows.find(r=>r.type==="toggle");
    assert.equal(f.framework.edit(page.handle,row.key,!row.value,page.revision).ok,true);
    assert.equal(t.pending.size,0,"disposed menu must unsubscribe from provider events");
    for(let i=0;i<120;i++)t.poll();
    assert.equal(f.reports.filter(e=>e.code==="MENU_FAILED").length,0);
    f.dispose();
});

test("an earlier cleanup failure cannot prevent task cancellation or reopening settings", () => {
    const t=timers(), f=fixture({timerApi:t.api});t.flush();
    f.state.hide=()=>{throw Error("synthetic layout failure");};
    f.state.dispose();
    assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);assert.equal(f.menu.states.size,0);
    assert.ok(f.reports.some(e=>e.code==="MENU_DISPOSE_STEP_FAILED"&&e.detail.includes("synthetic layout failure")));
    f.state.dispose();
    const reopened=f.menu.create(f.panel);assert.notEqual(reopened,f.state);assert.equal(reopened.disposed,false);
    reopened.dispose();assert.equal(f.menu.states.size,0);assert.equal(t.intervals.size,0);
    f.dispose();
});

test("one failing native row removal cannot strand subsequent row subscriptions", () => {
    const f=fixture(), first=f.bindHeader();f.bind(f.id);
    const second=f.state.entries.get(f.id);let removed=0;
    first.row.RemoveFromParent=()=>{throw Error("synthetic first row removal failure");};
    second.row.RemoveFromParent=()=>{removed++;};
    f.state.dispose();
    assert.equal(first.scope.live,false);assert.equal(second.scope.live,false);
    assert.equal(removed,1);assert.equal(f.state.entries.size,0);
    f.state.dispose();assert.equal(removed,1);f.dispose();
});

for (const failure of ["switcher", "detailRoot", "tabRemoval"]) test(`partial ${failure} failure still releases other native owners`, () => {
    const f=fixture(), layout=f.state.layout;
    if(failure==="switcher")f.panel.WidgetSwitcher_65.GetActiveWidget=()=>{throw Error("access a invalid object");};
    if(failure==="detailRoot")layout.detailRoot.RemoveFromParent=()=>{throw Error("access a invalid object");};
    if(failure==="tabRemoval")f.state.tabs.RemoveTab=()=>{throw Error("access a invalid object");};
    f.state.dispose();
    assert.equal(layout.root.attached,false,"main root must be removed independently");
    if(failure!=="detailRoot")assert.equal(layout.detailRoot.attached,false);
    assert.equal(f.state.tabs.TabButtonIDs.Num(),1,"navigation metadata must be released independently");
    assert.equal(f.menu.states.size,0);f.dispose();
});

test("external details restore the native visibility across normal close and reopen", () => {
    const f=fixture({externalDetails:true});
    try {
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Collapsed);
        f.state.hide();assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        f.state.show();assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Collapsed);
        f.state.dispose();assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        const reopened=f.menu.create(f.panel);
        reopened.show();reopened.dispose();
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
    } finally { f.dispose(); }
});

for (const operation of ["hide","dispose"]) for (const failure of ["detailRoot","preview","flush"])
test(`${operation} restores native details even when ${failure} cleanup fails`, () => {
    const t=timers(), f=fixture({externalDetails:true,timerApi:t.api});t.flush();
    const original=Error("access a invalid object");
    const target=failure==="detailRoot"?f.state.layout.detailRoot:failure==="preview"?f.state.previewPane:f.state;
    const method=failure==="detailRoot"?"SetVisibility":failure==="preview"?"hide":"flush";
    const saved=target[method];target[method]=()=>{throw original;};
    try {
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Collapsed,"fixture must exercise the hidden native detail area");
        if(operation==="hide")assert.throws(()=>f.state.hide(),error=>error===original);
        else f.state.dispose();
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible,"owned widget failure must not strand native details");
        target[method]=saved;f.state.dispose();
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        const reopened=f.menu.create(f.panel);
        reopened.show();reopened.dispose();
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible,"reopening must not preserve a poisoned hidden baseline");
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
    } finally { target[method]=saved;f.dispose(); }
});

for (const source of ["hostDeactivate","hostReactivate","listEntries","queuedRefresh"])
test(`a failed ${source} callback retires the real delegate scopes and stops retries`,()=>{
    const t=timers(),f=fixture({externalDetails:true,realLifetimes:true,timerApi:t.api});t.flush();
    const host=f.panel.SettingWidget;
    assert.equal(host.OnHostDeactivated.handlerCount(),1);assert.equal(host.OnHostReactivated.handlerCount(),1);
    let calls=0;
    const broken=()=>{calls++;throw Error("access a invalid object");};
    let fire;
    if(source==="hostDeactivate"){f.state.previewPane.hide=broken;fire=()=>host.OnHostDeactivated.emit();}
    else if(source==="hostReactivate"){f.state.show=broken;fire=()=>host.OnHostReactivated.emit();}
    else if(source==="listEntries"){f.state.focusReady=broken;fire=()=>f.state.list.BP_OnEntriesGenerated.emit();}
    else {f.state.refresh=broken;fire=()=>{f.state.queueRefresh();t.flush();};}
    try{
        fire();const afterFirst=calls;assert.ok(afterFirst>0);
        fire();fire();assert.equal(calls,afterFirst,"later native events must not re-enter the failed menu");
        assert.equal(f.state.disposed,true);assert.equal(f.menu.states.size,0);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(host.OnHostDeactivated.handlerCount(),0);assert.equal(host.OnHostReactivated.handlerCount(),0);
        assert.equal(f.state.list.BP_OnEntriesGenerated.handlerCount(),0);
        assert.equal(f.reports.filter(e=>e.code==="MENU_FAILED").length,1);
    }finally{f.dispose();}
});

test("a failing row click releases its real native delegate instead of repeating on further clicks",()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    try{
        f.bindHeader();t.flush();
        const model=[...f.state.models.values()].find(row=>row.type==="toggle");assert.ok(model);
        f.bind(model.id);
        const binding=f.state.entries.get(model.id),click=binding.control.OnButtonBaseClicked;
        assert.equal(click.handlerCount(),1);
        let calls=0;f.state.step=()=>{calls++;throw Error("access a invalid object");};
        click.emit();click.emit();click.emit();
        assert.equal(calls,1);assert.equal(click.handlerCount(),0);assert.equal(binding.scope.live,false);
        assert.equal(f.state.disposed,true);assert.equal(f.menu.states.size,0);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(f.reports.filter(e=>e.code==="MENU_FAILED").length,1);
    }finally{f.dispose();}
});

for(const [event,target,args] of [
    ["OnMouseEnter","select",[]], ["OnAddedToFocusPath","select",[]],
    ["BP_OnItemSelectionChanged","rowSelection",[true]],
    ["OnPreviewKeyDown","key",[{}, {key:"Right"}]], ["OnKeyUp","keyUp",[{}, {key:"Right"}]],
    ["OnAnalogValueChanged","analog",[{}, {key:"Gamepad_LeftX",value:1}]],
    ["OnMouseButtonDown","action",[{}, {key:"LeftMouseButton"}]]
])test(`native row ${event} retires a failing menu and ignores later events`,()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    let calls=0;const broken=()=>{calls++;throw Error("access a invalid object");};
    if(target==="rowSelection")f.state.entries.get(f.id).row.SetSelected=broken;else f.state[target]=broken;
    try{
        for(let i=0;i<3;i++)assert.doesNotThrow(()=>f.host[event](...args));
        assert.equal(calls,1);assert.equal(f.state.disposed,true);assert.equal(f.menu.states.size,0);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(f.reports.filter(e=>e.code==="MENU_FAILED").length,1);
    }finally{f.dispose();}
});

test("an invalid row refresh retires the menu and cannot repeat on later refresh requests",()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    try{
        const binding=f.state.entries.get(f.id);let calls=0;
        binding.control.PopulateTextLabels=()=>{calls++;throw Error("access a invalid object");};
        for(let i=0;i<3;i++){f.state.queueRefresh();t.flush();}
        assert.equal(calls,1);assert.equal(f.state.disposed,true);assert.equal(binding.scope.live,false);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(f.panel.SettingWidget.OnHostDeactivated.handlerCount(),0);
    }finally{f.dispose();}
});

for(const event of ["keyboard","mouse"])test(`invalid native ${event} capture retires the menu without retry`,()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    try{
        let calls=0;const broken=()=>{calls++;throw Error("access a invalid object");};
        Object.defineProperty(f.state.editors,"capturing",{get:()=>true});
        if(event==="keyboard")f.UE.SubsystemBlueprintLibrary.GetLocalPlayerSubsystem=broken;
        const input=event==="keyboard"?{key:"F8"}:{get key(){return broken();}};
        const fire=()=>event==="keyboard"?f.host.OnPreviewKeyDown({},input):f.host.OnPreviewMouseButtonDown({},input);
        fire();t.flush();fire();t.flush();
        assert.equal(calls,1);assert.equal(f.state.disposed,true);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(f.panel.SettingWidget.OnHostDeactivated.handlerCount(),0);
    }finally{f.dispose();}
});

test("initial binding of a destroyed row host retires once without touching fallback native fields",()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    try{
        const host=new f.host.constructor(),item=f.state.byId.get(f.id);let roots=0,fallbacks=0,created;
        const original=f.ui.widget;f.ui.widget=(...args)=>created=original(...args);
        Object.defineProperty(host,"WidgetTree",{get(){roots++;throw Error("access a invalid object");}});
        Object.defineProperty(host,"Text_SettingName",{get(){fallbacks++;throw Error("access a invalid object");}});
        for(let i=0;i<3;i++)assert.doesNotThrow(()=>host.OnListItemObjectSet(item));
        assert.equal(roots,1);assert.equal(fallbacks,0);assert.equal(created.attached,false);
        assert.equal(f.state.disposed,true);assert.equal(f.menu.states.size,0);
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
        assert.equal(f.panel.SettingWidget.OnHostDeactivated.handlerCount(),0);
        assert.equal(f.reports.filter(e=>e.code==="ROW_CREATE_FAILED").length,1);
    }finally{f.dispose();}
});

test("selection callbacks retiring the menu stop the outer edit before writing provider values",()=>{
    const t=timers(),f=fixture({realLifetimes:true,timerApi:t.api});t.flush();
    try{
        f.bindHeader();t.flush();const model=[...f.state.models.values()].find(row=>row.type==="toggle");
        f.bind(model.id);f.state.selected=f.id;f.panel.IsEnterSecond=false;
        let edits=0;f.framework.edit=()=>{edits++;return {ok:true};};
        f.state.previewPane.hide=()=>{throw Error("access a invalid object");};
        f.state.list.BP_SetSelectedItem=()=>f.panel.SettingWidget.OnHostDeactivated.emit();
        f.menu.protect(f.state,()=>f.state.edit(model.id,!model.value));
        assert.equal(f.state.disposed,true);assert.equal(edits,0);
        assert.equal(f.panel.IsEnterSecond,false,"retired selection cannot re-enter the second native page");
        assert.equal(t.intervals.size,0);assert.equal(t.pending.size,0);
    }finally{f.dispose();}
});
