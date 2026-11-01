"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const fs = require("node:fs"), path = require("node:path"), crypto = require("node:crypto");
const { createStore } = require("../provider/ConfigStore");
const { createJournal, decode } = require("../provider/Journal");
const { getHub, publishOptional } = require("../provider/Protocol");
const { createFramework } = require("../src/Framework");
const S = require("../provider/Schema"), C = require("../provider/Controls");
const { compatibleDescriptor } = require("../provider/Compatibility");
const { memoryIO, clock } = require("./fixtures.cjs");
const legacy = {
    ...require("./legacy-v1/provider/Protocol"),
    ...require("./legacy-v1/provider/ConfigStore"),
    ...require("./legacy-v1/src/Framework")
};
const {descriptor,setup}=require("./components-fixture.cjs");
test("冻结旧版夹具哈希未变，防止兼容测试偷偷随实现更新",()=>{
    const root=path.join(__dirname,"legacy-v1"), manifest=require("./legacy-v1/snapshot.json");
    for(const [name,hash] of Object.entries(manifest.sha256)) assert.equal(crypto.createHash("sha256").update(fs.readFileSync(path.join(root,name))).digest("hex"),hash);
});
test("原版提供者与旧文件进入新版框架：不迁移、不重写、不丢值",()=>{
    const spec=descriptor();spec.entries=spec.entries.filter(e=>["enabled","level","mode","save"].includes(e.key));
    const root={},io=memoryIO(),timer=clock();
    let store=legacy.createStore(spec,createJournal(io,"Components"),timer);
    store.apply({enabled:false,level:0.7,mode:"b"});store.flush();store.dispose();
    const before=[...io.files],writes=io.writes;
    store=legacy.createStore(spec,createJournal(io,"Components"),timer);
    const reg=legacy.publishOptional(store,root),framework=createFramework(legacy.getHub(root));
    assert.equal(framework.pages()[0].error,undefined);
    assert.deepEqual(framework.pages()[0].values,{enabled:false,level:0.7,mode:"b"});
    framework.setLanguage("ko");framework.pages();framework.flushAll();
    assert.deepEqual(io.files,before);assert.equal(io.writes,writes);
    const page=framework.pages()[0];assert.equal(framework.edit(page.handle,"level",0.8,page.revision).ok,true);
    framework.dispose();reg.dispose();store.dispose();
    store=legacy.createStore(spec,createJournal(io,"Components"),timer);
    assert.deepEqual(store.read().values,{enabled:false,level:0.8,mode:"b"});store.dispose();
});
for(const oldHub of [false,true])test(`新控件通过${oldHub?"旧":"新"}总线接入，先后加载保持所有权`,()=>{
    const x=setup({oldHub});try{
        assert.equal(x.page().error,undefined);assert.equal(x.page().rows.find(r=>r.key==="tint").type,"color");
        assert.equal(x.hub.protocol,1);assert.equal(Object.isFrozen(x.hub),true);
        assert.equal(x.page().handle.ownerToken,x.registration.ownerToken);
    }finally{x.dispose();}
});
test("新提供者配旧框架：旧设置可编辑，默认恢复不能清除扩展值",()=>{
    const x=setup({oldHub:true,oldFramework:true});try{
        x.store.apply({enabled:false,shortcut:"Ctrl+K",tint:"#01020304",sound:"tick",dependent:true,nested:true});
        const page=x.page();assert.equal(page.error,undefined);
        assert.deepEqual(Object.keys(page.values),["enabled","level","mode"]);
        assert.ok(page.rows.some(r=>r.type==="header"&&/0.3.0/.test(r.label)));
        assert.equal(x.framework.edit(page.handle,"level",0.9,page.revision).ok,true);
        assert.equal(x.framework.reset(page.handle,undefined,x.page().revision).ok,true);
        const values=x.store.read().values;
        assert.equal(values.level,0.5);assert.equal(values.enabled,true);
        assert.equal(values.shortcut,"Ctrl+K");assert.equal(values.tint,"#01020304");assert.equal(values.sound,"tick");
        assert.equal(values.dependent,true);assert.equal(values.nested,true);
        assert.equal(x.framework.action(page.handle,"save",x.page().revision).ok,true);
        assert.equal(compatibleDescriptor(x.store).apply({tint:"#FFFFFFFF"}).ok,false);
    }finally{x.dispose();}
});
test("没有扩展控件时保持原提供者身份",()=>{const p={entries:[{type:"toggle"}]};assert.equal(compatibleDescriptor(p),p);});
test("三类新值重新创建存储后保持，只有标量入盘",()=>{
    const x=setup();x.store.apply({shortcut:"Ctrl+Shift+K",tint:"#12233445",sound:"tick"});x.store.flush();const saved=JSON.stringify(x.io.files);x.dispose();
    const y=setup({io:x.io});try{assert.equal(y.store.read().values.shortcut,"Ctrl+Shift+K");assert.equal(y.store.read().values.tint,"#12233445");assert.equal(y.store.read().values.sound,"tick");assert.equal(JSON.stringify(y.io.files),saved);}finally{y.dispose();}
});
test("非法绑定、重复绑定、保留返回键与非法颜色不得写盘",()=>{
    const x=setup();try{ x.store.flush();const before=x.store.read(), files=[...x.io.files];
        for(const patch of [{shortcut:"Ctrl+Ctrl+K"},{shortcut:"Shift+Ctrl+K"},{shortcut:"Escape"},{shortcut:"Gamepad_FaceButton_Right"},{shortcut:"LeftShift"},{shortcut:"Ctrl+G"},{tint:"#FFF"},{tint:{r:1}},{sound:"missing"}])assert.equal(x.store.apply(patch).ok,false,JSON.stringify(patch));
        assert.deepEqual(x.store.read(),before);assert.deepEqual(x.io.files,files);
        assert.equal(x.store.apply({shortcut:"Ctrl+G",alternate:"F"}).ok,true,"atomic swap is valid");
    }finally{x.dispose();}
});
test("按键设备限制与颜色透明度约束",()=>{
    assert.equal(C.bindingError({allowModifiers:false},"Ctrl+K"),"MODIFIERS_DISABLED");
    assert.equal(C.bindingError({allowMouse:false},"LeftMouseButton"),"MOUSE_BINDING_DISABLED");
    assert.equal(C.bindingError({allowGamepad:false},"Gamepad_FaceButton_Left"),"GAMEPAD_BINDING_DISABLED");
    assert.equal(C.bindingError({allowedKeys:["F"]},"G"),"KEY_NOT_ALLOWED");
    assert.equal(C.colorError({},"#12345678"),"INVALID_COLOR");assert.equal(C.colorError({},"#aAbBcC"),null);
    assert.equal(C.colorValue(C.colorChannels("#AABBCCDD")),"#AABBCCDD");
});
test("试听不写配置，重复试听及切换音效停止前一段",()=>{
    const calls=[],x=setup({sounds:{sound:value=>{calls.push(value);return()=>calls.push("stop:"+value);}}});try{
        x.store.flush();const saved=[...x.io.files];
        let p=x.page();assert.equal(x.framework.preview(p.handle,"sound",p.revision).ok,true);
        assert.equal(x.framework.preview(p.handle,"sound",p.revision).ok,true);
        assert.deepEqual(calls,["bell","stop:bell","bell"]);assert.deepEqual(x.io.files,saved);
        x.framework.edit(p.handle,"sound","tick",p.revision);assert.equal(calls.at(-1),"stop:bell");
        p=x.page();x.framework.preview(p.handle,"sound",p.revision);x.framework.stopPreview();x.framework.stopPreview();
        assert.deepEqual(calls.slice(-2),["tick","stop:tick"]);
    }finally{x.dispose();}
});
test("禁用、过期、异常试听独立报错，提供者替换清理",()=>{
    let stops=0;const x=setup({sounds:{sound:()=>()=>{stops++;}}});try{
        let p=x.page();assert.equal(x.framework.preview(p.handle,"sound",p.revision+1).error,"REVISION_CONFLICT");
        x.store.apply({enabled:false});p=x.page();assert.equal(x.framework.preview(p.handle,"sound",p.revision).error,"DISABLED");
        x.store.apply({enabled:true});p=x.page();x.framework.preview(p.handle,"sound",p.revision);x.registration.dispose();assert.equal(stops,1);
        assert.equal(x.framework.preview(p.handle,"sound",p.revision).error,"STALE_PROVIDER");
    }finally{x.dispose();}
    const y=setup({sounds:{sound:()=>{throw Error("device unavailable");}}});try{
        const p=y.page();assert.equal(y.framework.preview(p.handle,"sound",p.revision).ok,false);assert.equal(y.page().error,undefined);
    }finally{y.dispose();}
});
test("三类新值真正跨独立进程读取，二次启动不重写文件",()=>{
    const os=require("node:os"),{spawnSync}=require("node:child_process");
    const directory=fs.mkdtempSync(path.join(os.tmpdir(),"pbz-components-"));
    try{
        const run=mode=>{const r=spawnSync(process.execPath,[path.join(__dirname,"components-child.cjs"),directory,mode],{encoding:"utf8"});assert.equal(r.status,0,r.stderr);return JSON.parse(r.stdout);};
        const written=run("write");
        const files=()=>[0,1].map(slot=>{const p=path.join(directory,"Components",String(slot),"New_CSV.csv");return fs.existsSync(p)?fs.readFileSync(p,"utf8"):null;});
        const before=files(),read=run("read");assert.deepEqual(read,written);assert.deepEqual(files(),before);
        assert.equal(read.values.shortcut,"Ctrl+Shift+K");assert.equal(read.values.tint,"#12345678");assert.equal(read.values.sound,"tick");assert.equal(read.values.level,0.7);
    }finally{fs.rmSync(directory,{recursive:true,force:true});}
});
test("试听回调中注销、改值或释放存储不会留下播放",()=>{
    for(const action of [x=>x.registration.dispose(),x=>x.store.apply({sound:"tick"}),x=>x.store.dispose()]){
        let x,stops=0;x=setup({sounds:{sound:()=>{action(x);return()=>stops++;}}});
        try{const p=x.page();assert.equal(x.framework.preview(p.handle,"sound",p.revision).ok,false);assert.equal(stops,1);x.framework.stopPreview();assert.equal(stops,1);}finally{x.dispose();}
    }
});
test("提供者读值故障立即停止试听，不拖累其他模组",()=>{
    const root={},store=createStore(descriptor(),createJournal(memoryIO(),"Components"),clock());
    let broken=false,stops=0;
    const provider={...store,read(){if(broken)throw Error("lost source");return store.read();},previewSound(){return{ok:true,stop:()=>stops++};}};
    const reg=publishOptional(provider,root),framework=createFramework(getHub(root),{report:()=>{}});
    try{const p=framework.pages()[0];assert.equal(framework.preview(p.handle,"sound",p.revision).ok,true);broken=true;assert.ok(framework.pages()[0].error);assert.equal(stops,1);}finally{framework.dispose();reg.dispose();store.dispose();}
});
test("旧提供者升级接入层并增添控件，已有值原样保留且无须迁移",()=>{
    const spec=descriptor(),oldSpec={...spec,entries:spec.entries.filter(e=>["enabled","level","mode","save"].includes(e.key))};
    const io=memoryIO(),timer=clock(),old=legacy.createStore(oldSpec,createJournal(io,"Components"),timer);
    old.apply({enabled:false,level:0.7,mode:"b"});old.flush();old.dispose();
    const extended=createStore(spec,createJournal(io,"Components"),timer);
    try{const values=extended.read().values;assert.equal(values.enabled,false);assert.equal(values.level,0.7);assert.equal(values.mode,"b");assert.equal(values.shortcut,"F");assert.equal(extended.flush().ok,true);}finally{extended.dispose();}
});
test("框架直接切换试听也尊重旧停止回调中的取消",()=>{
    let x,starts=0,stops=0;
    x=setup({sounds:{sound:()=>{starts++;return()=>{stops++;x.framework.stopPreview();};}}});
    try{
        const p=x.page();assert.equal(x.framework.preview(p.handle,"sound",p.revision).ok,true);
        assert.equal(x.framework.preview(p.handle,"sound",p.revision).error,"PREVIEW_CHANGED");assert.equal(starts,1);assert.equal(stops,1);
    }finally{x.dispose();}
});
