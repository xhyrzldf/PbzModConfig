"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {fixture}=require("./native-input-fixture.cjs");
const {createFooter}=require("../native/NativeFooter");
const {createSupport}=require("../native/NativeSupport");

function footerFixture(){
    let next=0;
    const intervals=new Map(),pending=new Map();
    const f=fixture({realFooter:true,realLifetimes:true,externalDetails:true,timerApi:{
        setInterval(fn){intervals.set(++next,fn);return next;},clearInterval(id){intervals.delete(id);},
        setTimeout(fn){pending.set(++next,fn);return next;},clearTimeout(id){pending.delete(id);}
    }});
    while(pending.size){const [id,fn]=pending.entries().next().value;pending.delete(id);fn();}
    f.state.footer.update(true);
    assert.equal(f.footerLinks.length,1);assert.equal(typeof f.footerLinks[0].click,"function");
    return {...f,link:f.footerLinks[0],intervals,pending};
}

for(const failure of ["event", "acceptsInput", "launch"]){
    test(`footer ${failure} failure retires the real menu once, including queued old clicks`,()=>{
        const f=footerFixture(),click=f.link.click;let reads=0;
        const fail=()=>{reads++;throw Error("access a invalid object");};
        if(failure==="event")f.UE.KismetInputLibrary.PointerEvent_GetEffectingButton=fail;
        if(failure==="acceptsInput")f.state.acceptsInput=fail;
        if(failure==="launch")f.UE.KismetSystemLibrary.LaunchURL=fail;
        const escaped=[],replies=[];
        for(let i=0;i<3;i++)try{replies.push(click({}, {key:"LeftMouseButton"}));}catch(e){escaped.push(e.message);}
        assert.deepEqual(escaped,[],"native callback exceptions must not escape to the engine");
        assert.deepEqual(replies,["unhandled","unhandled","unhandled"]);
        assert.equal(reads,1,"late clicks must not re-enter the failed native call");
        assert.equal(f.state.disposed,true);assert.equal(f.state.scope.live,false);
        assert.equal(f.menu.states.size,0);assert.equal(f.intervals.size,0);assert.equal(f.pending.size,0);
        assert.equal(f.panel.SettingWidget.OnHostDeactivated.handlerCount(),0);
        assert.equal(f.panel.SettingWidget.OnHostReactivated.handlerCount(),0);
        assert.equal(f.state.list.BP_OnEntriesGenerated.handlerCount(),0);
        assert.equal(f.link.click,null);assert.equal(f.state.entries.size,0);assert.equal(f.state.models.size,0);
        assert.equal(f.state.layout.root.attached,false);assert.equal(f.state.layout.detailRoot.attached,false);
        assert.equal(f.panel.Details_Settings.visibility,0);
        assert.equal(f.reports.filter(e=>e.code==="AUTHOR_LINK_INPUT_FAILED").length,1);
        const page=f.framework.pages()[0],row=page.rows.find(r=>r.type==="toggle");
        assert.equal(f.framework.edit(page.handle,row.key,!row.value,page.revision).ok,true);
        assert.equal(f.pending.size,0,"provider updates must not schedule the retired menu");
        f.dispose();
    });
}

test("real footer handles a normal left click, ignores hidden and covered input, and releases its delegate",()=>{
    const f=footerFixture(),click=f.link.click;
    assert.equal(click({}, {key:"RightMouseButton"}),"unhandled");
    assert.equal(click({}, {key:"LeftMouseButton"}),"handled");
    assert.equal(f.calls.filter(c=>c[0]==="url").length,1);
    f.UE.KismetInputLibrary.PointerEvent_GetEffectingButton=()=>{throw Error("hidden event must not be read");};
    f.state.footer.update(false);assert.equal(click({}, {}),"unhandled");
    f.state.footer.update(true);f.state.cover();assert.equal(click({}, {}),"unhandled");
    assert.equal(f.state.disposed,false);f.dispose();
    assert.equal(f.link.click,null);assert.equal(click({}, {}),"unhandled");
    assert.equal(f.intervals.size,0);
});

test("partial footer binding failure can unwind the already bound delegate",()=>{
    const f=footerFixture();f.dispose();
    const scope=createSupport({},()=>{}).lifetime();let bound=null,unbound=0;
    const failure=Error("access a invalid object");
    const link={SetBrushColor(){},SetPadding(){},SetContent(){},SetRenderOpacity(){},
        OnMouseButtonDownEvent:{Bind(fn){bound=fn;throw failure;},Unbind(){bound=null;unbound++;}}};
    const state={detailView:f.state.detailView,scope};
    const ui={...f.ui,native:()=>link};
    assert.throws(()=>createFooter(f.UE,ui,state,()=>{}),e=>e===failure,
        "the owning menu creation boundary must see and retire a failed native binding");
    scope.dispose();assert.equal(bound,null);assert.equal(unbound,1);
});
