"use strict";
const test=require("node:test"), assert=require("node:assert/strict");
const fs=require("node:fs"), path=require("node:path"), vm=require("node:vm");
const {createRequire}=require("node:module");
const {fixture}=require("./native-input-fixture.cjs");

// Real Entry wrappers and real NativeMenu/Framework; only engine widgets and
// bootstrap wiring are replaced. No game process, filesystem IO or real timers.
function entryFixture({nativeSwitchError,realLifetimes=false,realPreview=false}={}) {
    let id=0;const intervals=new Map(), pending=new Map(), calls=new Map();
    const fixtureOptions={externalDetails:true,realLifetimes,realPreview,timerApi:{
        setInterval(fn){intervals.set(++id,fn);return id;},clearInterval(key){intervals.delete(key);},
        setTimeout(fn){pending.set(++id,fn);return id;},clearTimeout(key){pending.delete(key);}
    }};
    const f=fixture(fixtureOptions);
    for(let limit=50;pending.size;limit--){
        assert.ok(limit>0,"fixture setup must settle");const [key,fn]=pending.entries().next().value;pending.delete(key);fn();
    }
    class Panel {}
    const names=["BP_InitWidget","applyTabSwitch","selectFirstSettingDeferred","SelectWidgetToFocus","ClickCollection","selectCollection",
        "handleResetKeyPressed","backInputInternal","StartResetBindingRecovery","FinishCurrentWidget"];
    for(const name of names) Panel.prototype[name]=function(...args){
        calls.set(name,(calls.get(name)||0)+1);
        if(name==="applyTabSwitch") {if(nativeSwitchError)throw nativeSwitchError;this.CurrentCollection=args[1];}
        return "native:"+name;
    };
    Object.setPrototypeOf(f.panel,Panel.prototype);
    const host={};for(const name of ["invalidateResetKeyMemory","releasePanelHostBinding","cancelResolutionTransactionForClosedPanel"])
        host[name]=()=>{calls.set(name,(calls.get(name)||0)+1);return "native:"+name;};
    const nativeLifecycle={clearPendingSelect(){},cancelSelectWidgetFocusTimer(){}};
    const filename=path.join(__dirname,"../native/Entry.js"), realRequire=createRequire(filename);
    const context={module:{exports:{}},require(name){
        if(name==="./NativeMenu")return {createMenu:(_UE,_puerts,_framework,report)=>{fixtureOptions.report=report;return f.menu;}};
        if(name==="../src/Framework")return {createFramework:()=>f.framework};
        return realRequire(name);
    }};
    vm.runInNewContext(fs.readFileSync(filename,"utf8"),context,{filename});
    const runtime=context.module.exports.install(Panel,{}, {},host,nativeLifecycle,{});
    return {...f,runtime,host,nativeLifecycle,intervals,pending,calls};
}

test("entry preserves normal native switching, mod reopening and native return values",()=>{
    const f=entryFixture();try{
        const native={};assert.equal(f.panel.applyTabSwitch("Video",native),"native:applyTabSwitch");
        assert.equal(f.state.active,false);assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        assert.equal(f.panel.applyTabSwitch("PbzModConfig",f.state.collection),"native:applyTabSwitch");
        assert.equal(f.state.active,true);assert.equal(f.calls.get("applyTabSwitch"),2);
        assert.equal(f.runtime.diagnostics.snapshot().events.some(e=>e.code==="MENU_FAILED"),false);
    }finally{f.dispose();}
});

for(const message of ["access a invalid object","unexpected native visibility failure"])
test(`entry switching retires failed owned details and still runs native switching: ${message}`,()=>{
    const f=entryFixture();try{
        f.state.layout.detailRoot.SetVisibility=()=>{throw Error(message);};
        for(let i=0;i<2;i++)assert.equal(f.panel.applyTabSwitch("Video",{}),"native:applyTabSwitch");
        assert.equal(f.calls.get("applyTabSwitch"),2);
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        assert.equal(f.menu.states.size,0);assert.equal(f.state.disposed,true);
        assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
        const failures=f.runtime.diagnostics.snapshot().events.filter(e=>e.code==="MENU_FAILED");
        assert.equal(failures.length,1);assert.equal(failures[0].count,1,"retired state must not be retried on every native event");
        assert.equal(f.panel.BP_InitWidget(),"native:BP_InitWidget");
        assert.equal(f.menu.states.size,0,"the same failed native panel must not re-install the mod");
    }finally{f.dispose();}
});

test("entry does not swallow or retry a failure originating in the native switch handler",()=>{
    const original=Error("native game switch failure"),f=entryFixture({nativeSwitchError:original});
    try{assert.throws(()=>f.panel.applyTabSwitch("Video",{}),error=>error===original);assert.equal(f.calls.get("applyTabSwitch"),1);}
    finally{f.dispose();}
});

const cases=[
    ["backInputInternal","flush",true],
    ["selectFirstSettingDeferred","focusReady",false],
    ["SelectWidgetToFocus","focusReady",false],
    ["ClickCollection","show",false],
    ["selectCollection","show",false],
    ["handleResetKeyPressed","action",false],
    ["StartResetBindingRecovery","resume",true],
    ["BP_InitWidget","bindHost",true],
    ["invalidateResetKeyMemory","cover",true]
];
for(const [entry,method,native] of cases)test(`entry ${entry} contains mod failure and retires its polling`,()=>{
    const f=entryFixture(),saved=f.state[method];
    f.state[method]=()=>{throw Error("access a invalid object");};
    try{
        assert.doesNotThrow(()=>entry in f.host?f.host[entry](f.panel):f.panel[entry](f.state.collection));
        assert.equal(f.calls.get(entry)||0,native?1:0,"native-only continuation must keep its original execution contract");
        assert.equal(f.menu.states.size,0);assert.equal(f.state.disposed,true);
        assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
        assert.ok(f.runtime.diagnostics.snapshot().events.some(e=>e.code==="MENU_FAILED"||e.code==="MENU_INSTALL_FAILED"));
    }finally{f.state[method]=saved;f.dispose();}
});

test("an invalid CurrentCollection getter cannot skip native back handling or keep the menu alive",()=>{
    const f=entryFixture(),saved=Object.getOwnPropertyDescriptor(f.panel,"CurrentCollection");
    Object.defineProperty(f.panel,"CurrentCollection",{configurable:true,get(){throw Error("access a invalid object");}});
    try{
        for(let i=0;i<2;i++)assert.equal(f.panel.backInputInternal(),"native:backInputInternal");
        assert.equal(f.calls.get("backInputInternal"),2);assert.equal(f.state.disposed,true);
        assert.equal(f.menu.states.size,0);assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
        assert.equal(f.runtime.diagnostics.snapshot().events.find(e=>e.code==="MENU_FAILED").count,1);
    }finally{Object.defineProperty(f.panel,"CurrentCollection",saved);f.dispose();}
});

test("a host callback failure is remembered by the entry without re-installing the same panel",()=>{
    const f=entryFixture({realLifetimes:true});
    try{
        f.state.cover=()=>{throw Error("access a invalid object");};
        f.panel.SettingWidget.OnHostDeactivated.emit();
        for(let i=0;i<3;i++)assert.equal(f.panel.BP_InitWidget(),"native:BP_InitWidget");
        assert.equal(f.menu.states.size,0);assert.equal(f.intervals.size,0);
        const events=f.runtime.diagnostics.snapshot().events;
        assert.equal(events.find(e=>e.code==="MENU_FAILED").count,1);
        assert.equal(events.some(e=>e.code==="MENU_INSTALL_FAILED"),false);
        assert.equal(f.panel.backInputInternal(),"native:backInputInternal");
    }finally{f.dispose();}
});

test("a real preview failure cannot reactivate the removed layout after native tab switching",()=>{
    const f=entryFixture({realLifetimes:true,realPreview:true});
    try{
        f.panel.applyTabSwitch("Video",{});
        // Keep the real preview implementation; fail its first native widget operation.
        f.framework.hasVisual=()=>true;
        f.state.detailView.Box_DetailsExtension={};
        let calls=0;const original=f.ui.native;
        f.ui.native=(owner,kind)=>kind==="SizeBox"?{SetWidthOverride(){calls++;throw Error("access a invalid object");},SetVisibility(){},RemoveFromParent(){}}:original(owner,kind);
        // Refresh rebuilds the header model; using the real provider preview query
        // plus a selected model after refresh exercises the details/show continuation.
        const originalDetails=f.state.details;
        f.state.details=()=>{const m=f.state.models.get(f.state.byId.get(f.id));m.section=false;m.key="tint";originalDetails();};
        assert.equal(f.panel.applyTabSwitch("PbzModConfig",f.state.collection),"native:applyTabSwitch");
        assert.equal(calls,1);assert.equal(f.state.disposed,true);
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        assert.notEqual(f.panel.WidgetSwitcher_65.GetActiveWidget(),f.state.layout.root);
        assert.equal(f.state.layout.root.attached,false);
        assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
    }finally{f.dispose();}
});

for(const trigger of ["PopulateTextLabels","SetSelectedItem"])
test(`a synchronous ${trigger} delegate cannot resume native updates after retiring its menu`,()=>{
    const f=entryFixture({realLifetimes:true});
    try{
        f.bindHeader();
        const model=[...f.state.models.values()].find(row=>row.type==="toggle");f.bind(model.id);
        const control=f.state.entries.get(model.id).control,afterRetirement=[];
        f.panel.applyTabSwitch("Video",{});
        let reads=0;control.GetSelectedIndex=()=>{reads++;throw Error("access a invalid object");};
        for(const name of ["PopulateTextLabels","SetSelectedItem"]){
            const original=control[name];control[name]=(...args)=>{
                if(f.state.disposed)afterRetirement.push(name);
                original.apply(control,args);if(name===trigger)control.OnRotated.emit();
            };
        }
        const originalFont=control.Text.SetFont;
        control.Text.SetFont=font=>{if(f.state.disposed)afterRetirement.push("SetFont");originalFont.call(control.Text,font);};
        assert.equal(f.panel.applyTabSwitch("PbzModConfig",f.state.collection),"native:applyTabSwitch");
        assert.equal(reads,1);assert.equal(f.state.disposed,true);
        assert.deepEqual(afterRetirement,[],"a dead row cannot receive selection or typography updates");
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
        assert.notEqual(f.panel.WidgetSwitcher_65.GetActiveWidget(),f.state.layout.root);
        assert.equal(f.state.models.size,0);assert.equal(f.state.entries.size,0);
        assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
        f.panel.applyTabSwitch("Video",{});
        assert.equal(f.panel.Details_Settings.GetVisibility(),f.ui.V.Visible);
    }finally{f.dispose();}
});
