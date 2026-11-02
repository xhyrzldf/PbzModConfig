"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const P=require("../src/ColorPalette"),{createEditors}=require("../src/Editors"),{setup,descriptor}=require("./components-fixture.cjs");
const {getHub,publishOptional}=require("../provider/Protocol"),{createStore}=require("../provider/ConfigStore"),{createJournal}=require("../provider/Journal"),{createFramework}=require("../src/Framework");
const {memoryIO,clock}=require("./fixtures.cjs"),{fixture}=require("./native-input-fixture.cjs");
test("调色盘主色、中心白、亮度和透明度一致；颜色可往返而不换色彩空间",()=>{
    assert.equal(P.wheel("#FFFFFF80",180,90,180),"#FF000080");
    assert.equal(P.wheel("#FFFFFF",90,0,180),"#80FF00");
    assert.equal(P.wheel("#000000",90,90,180),"#FFFFFF");
    assert.equal(P.wheel("#FFFFFF",-1,90,180),null);
    assert.equal(P.brightness("#FF000080",.5),"#80000080");
    for(const hex of ["#E0B35B","#8E0000","#61AFDD","#DD5045","#40A070"]){const c=P.hsv(hex);assert.deepEqual(P.rgb(c.h,c.s,c.v),hex.slice(1).match(/../g).map(x=>parseInt(x,16)));const m=P.marker(hex,180);assert.equal(P.wheel(hex,m.x,m.y,180),hex);}
});
test("调色盘只写草稿，非法值和过期修订不能保存；取消还原",()=>{
    const x=setup(),ed=createEditors(x.framework,{word:k=>k,refresh(){}});try{
        const p=x.page(),row={...p.rows.find(r=>r.key==="tint"),page:p},before=x.store.read();
        ed.action(ed.rows(row)[0]);assert.equal(ed.pickColor("#00FF0080"),true);assert.equal(ed.pickColor("#NOPE"),false);
        assert.equal(ed.colorDraft,"#00FF0080");assert.deepEqual(x.store.read(),before);
        ed.cancel();assert.deepEqual(x.store.read(),before);
        ed.action(ed.rows(row)[0]);ed.pickColor("#AA2200FF");x.store.apply({mode:"b"});
        ed.reconcile(new Map([[row.id,{...row,page:x.page()}]]));assert.equal(ed.colorDraft,null);
    }finally{ed.close();x.dispose();}
});
test("真实声音行选择和试听合一，鼠标与确认键试听，切换值立即停旧声",()=>{
    let starts=0,stops=0,store;
    const f=fixture({liveActions:true,createProvider(root){const s=descriptor();s.modId="PbzMapTracker";store=createStore(s,createJournal(memoryIO(),s.modId),{...clock(),sounds:{sound:()=>{starts++;return()=>stops++;}}});const r=publishOptional(store,root);return{dispose(){r.dispose();store.dispose();}};}});
    try{
        f.state.action(f.id);f.state.refresh();const id="PbzMapTracker/sound";
        assert.equal([...f.state.byId.keys()].filter(k=>k.startsWith(id)).length,1);
        f.bind(id);const b=f.state.entries.get(id);assert.ok(b.previewControl);assert.equal(b.previewControl.selectedText,"Preview");
        b.previewControl.OnButtonBaseClicked.emit();assert.equal(starts,1);
        f.state.step(id,1);assert.equal(stops,1);assert.equal(store.read().values.sound,"tick");
        f.state.key(id,"Enter",false);assert.equal(starts,2);f.state.hide();assert.equal(stops,2);
    }finally{f.dispose();}
});
test("预览只接收快照与合法颜色草稿，旧提供者仍可使用；替换和关闭释放一次",()=>{
    const root={},hub=getHub(root),frames=[],io=memoryIO(),store=createStore(descriptor(),createJournal(io,"Components"),clock());let ended=0;
    const reg=publishOptional({...store,createVisualPreview:()=>({update:f=>frames.push(f),dispose:()=>ended++})},root);
    const fw=createFramework(hub),p=fw.pages()[0],preview=fw.openVisual(p.handle,{});assert.equal(preview.ok,true);
    const before=store.read();preview.update("tint",{key:"tint",revision:p.revision,value:"#33CC55FF"});assert.equal(frames[0].values.tint,"#33CC55FF");assert.deepEqual(store.read(),before);
    frames[0].values.mode="tampered";assert.equal(store.read().values.mode,"a");
    preview.update("level",{key:"level",revision:p.revision,value:1});assert.equal(frames.at(-1).values.level,.5);
    preview.update("tint",{key:"tint",revision:p.revision+1,value:"#FFFFFFFF"});assert.equal(frames.at(-1).values.tint,before.values.tint);
    const next=publishOptional(store,root);assert.equal(ended,1);assert.equal(preview.update("tint"),false);assert.equal(fw.hasVisual(fw.pages()[0].handle),false);preview.dispose();assert.equal(ended,1);
    fw.dispose();next.dispose();reg.dispose();store.dispose();
});
test("预览更新异常仅关闭预览，不阻断配置；创建期间提供者被替换不能复活",()=>{
    const root={},hub=getHub(root),store=createStore(descriptor(),createJournal(memoryIO(),"Components"),clock()),events=[];let ended=0;
    let reg=publishOptional({...store,createVisualPreview:()=>({update(){throw Error("preview_only");},dispose:()=>ended++})},root);
    const fw=createFramework(hub,{report:e=>events.push(e)}),p=fw.pages()[0],v=fw.openVisual(p.handle,{});assert.equal(v.update("tint"),false);assert.equal(ended,1);assert.equal(fw.edit(p.handle,"mode","b",p.revision).ok,true);
    reg.dispose();reg=publishOptional({...store,createVisualPreview(){publishOptional(store,root);return{update(){},dispose:()=>ended++};}},root);
    assert.equal(fw.openVisual(fw.pages()[0].handle,{}).ok,false);assert.equal(ended,2);assert.ok(events.some(e=>e.code==="VISUAL_PREVIEW_FAILED"));fw.dispose();reg.dispose();store.dispose();
});
test("停止回调重入创建预览时，外层不覆盖或遗留新的预览",()=>{
    const root={},hub=getHub(root),store=createStore(descriptor(),createJournal(memoryIO(),"Components"),clock());
    let fw,handle,reenter=true,created=0,ended=0,newer;
    const reg=publishOptional({...store,createVisualPreview:()=>{created++;return{update(){},dispose(){ended++;if(reenter){reenter=false;newer=fw.openVisual(handle,{});}}};}},root);
    fw=createFramework(hub);handle=fw.pages()[0].handle;fw.openVisual(handle,{});
    assert.equal(fw.openVisual(handle,{}).error,"PREVIEW_CHANGED");assert.equal(created,2);assert.equal(newer.update("tint"),true);
    fw.dispose();assert.equal(ended,2);reg.dispose();store.dispose();
});
test("可选预览白名单属于各模组，非外观行不打开；非法清单只禁用预览，旧提供者保持可用",()=>{
    const root={},store=createStore(descriptor(),createJournal(memoryIO(),'Components'),clock());let ended=0;
    const reg=publishOptional({...store,visualPreviewKeys:['tint'],createVisualPreview:()=>({update(){},dispose(){ended++;}})},root);
    const fw=createFramework(getHub(root)),p=fw.pages()[0];assert.equal(fw.hasVisual(p.handle,'tint'),true);assert.equal(fw.hasVisual(p.handle,'sound'),false);assert.equal(fw.hasVisual(p.handle,'@reset'),false);
    const v=fw.openVisual(p.handle,{});assert.equal(v.update('tint'),true);assert.equal(v.update('sound'),false);assert.equal(ended,1);
    reg.dispose();const events=[],bad=publishOptional({...store,visualPreviewKeys:['missing'],createVisualPreview:()=>({update(){},dispose(){}})},root);
    const second=createFramework(getHub(root),{report:e=>events.push(e)}),q=second.pages()[0];assert.equal(second.hasVisual(q.handle,'tint'),false);assert.equal(second.edit(q.handle,'mode','b',q.revision).ok,true);assert.ok(events.some(e=>e.code==='VISUAL_PREVIEW_KEYS_INVALID'));
    second.dispose();bad.dispose();fw.dispose();store.dispose();
});
