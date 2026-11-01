"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {createEditors}=require("../src/Editors"),{setup,descriptor}=require("./components-fixture.cjs"),{clock,memoryIO}=require("./fixtures.cjs");
const {fixture}=require("./native-input-fixture.cjs");
const {createStore}=require("../provider/ConfigStore"),{createJournal}=require("../provider/Journal"),{publishOptional}=require("../provider/Protocol");
function editorFixture(options={}){
    const x=setup(options),timer=clock();let refreshes=0;
    const editor=createEditors(x.framework,{...timer,word:k=>k,refresh:()=>refreshes++});
    function models(){const p=x.page();return new Map(p.rows.map(r=>[r.id,{...r,page:p}]));}
    const row=key=>models().get("Components/"+key);
    return {...x,editor,timer,row,models,rows:key=>editor.rows(row(key)),close(){editor.close();x.dispose();}};
}
test("颜色拖动只改草稿，取消、换行、关闭均不写盘",()=>{
    for(const cancel of [x=>x.editor.action(x.rows("tint").at(-1)),x=>x.editor.key("Escape",false),x=>x.editor.select("Components/mode"),x=>x.editor.close()]){
        const x=editorFixture();try{
            x.store.flush();const before=x.store.read(),files=[...x.io.files];
            x.editor.action(x.rows("tint")[0]);const channel=x.rows("tint").find(r=>r.editorChannel===0);
            x.editor.edit(channel,200);assert.equal(x.editor.colorDraft,"#C82A36FF");assert.deepEqual(x.store.read(),before);
            cancel(x);assert.equal(x.editor.colorDraft,null);assert.deepEqual(x.store.read(),before);assert.deepEqual(x.io.files,files);
        }finally{x.close();}
    }
});
test("确认颜色原子写入；外部修订或提供者替换使草稿失效",()=>{
    const x=editorFixture();try{
        x.editor.action(x.rows("tint")[0]);x.editor.edit(x.rows("tint").find(r=>r.editorChannel===3),120);
        x.editor.action(x.rows("tint").find(r=>r.editorAction==="applyColor"));assert.equal(x.store.read().values.tint,"#B02A3678");
        x.editor.action(x.rows("tint")[0]);x.editor.edit(x.rows("tint").find(r=>r.editorChannel===0),1);
        x.store.apply({mode:"b"});x.editor.reconcile(x.models());assert.equal(x.editor.colorDraft,null);assert.equal(x.store.read().values.tint,"#B02A3678");
        x.editor.action(x.rows("tint")[0]);x.registration.dispose();x.editor.reconcile(new Map());assert.equal(x.editor.colorDraft,null);
    }finally{x.close();}
});
test("自由改键支持修饰键；冲突和重复输入不覆盖现值，按键抬起仍被吞掉",()=>{
    const x=editorFixture();try{
        x.editor.action(x.rows("shortcut")[0]);x.editor.key("LeftControl",false);x.editor.key("G",false,{Ctrl:true});
        assert.equal(x.editor.feedback.code,"BINDING_CONFLICT");assert.equal(x.store.read().values.shortcut,"F");
        x.editor.key("K",true,{Ctrl:true});assert.equal(x.store.read().values.shortcut,"F");
        x.editor.keyUp("K");x.editor.key("K",false,{Ctrl:true,Shift:true});
        assert.equal(x.store.read().values.shortcut,"Ctrl+Shift+K");assert.equal(x.editor.capturing,false);
        assert.equal(x.editor.keyUp("K"),true);assert.equal(x.editor.keyUp("K"),false);
    }finally{x.close();}
});
test("捕获时页签键作为绑定，取消后恢复；清除绑定是显式操作",()=>{
    const x=editorFixture();try{
        x.editor.action(x.rows("shortcut")[0]);assert.equal(x.editor.key("Z",false),true);assert.equal(x.store.read().values.shortcut,"Z");
        x.editor.keyUp("Z");assert.equal(x.editor.key("Z",false),false);
        x.editor.action(x.rows("shortcut")[0]);x.editor.key("Escape",false);assert.equal(x.store.read().values.shortcut,"Z");
        x.editor.action(x.rows("shortcut")[0]);x.editor.action(x.rows("shortcut").find(r=>r.editorAction==="clear"));assert.equal(x.store.read().values.shortcut,"");
    }finally{x.close();}
});
test("声音试听五秒自动停止，关闭后不留计时器和播放",()=>{
    let starts=0,stops=0;const x=editorFixture({sounds:{sound:()=>{starts++;return()=>stops++;}}});try{
        x.editor.action(x.rows("sound")[1]);assert.equal(starts,1);x.timer.advance(5000);assert.equal(stops,1);
        x.editor.action(x.rows("sound")[1]);x.editor.close();x.timer.advance(10000);assert.equal(starts,2);assert.equal(stops,2);assert.equal(x.timer.count(),0);
    }finally{x.close();}
});
test("试听启动回调中关闭编辑器，当场停止且不重新建立超时任务",()=>{
    let x,stops=0;x=editorFixture({sounds:{sound:()=>{x.editor.close();return()=>stops++;}}});
    try{x.editor.action(x.rows("sound")[1]);assert.equal(stops,1);assert.equal(x.timer.count(),0);assert.equal(x.rows("sound")[1].buttonLabel,"preview");}finally{x.close();}
});
function nativeFixture(onPreview=()=>()=>{},editSpec=()=>{}){
    let store;
    const f=fixture({liveActions:true,heldKeys:["LeftControl"],createProvider(root){
        const spec=descriptor();spec.modId="PbzMapTracker";
        editSpec(spec);
        store=createStore(spec,createJournal(memoryIO(),spec.modId),{...clock(),sounds:Object.fromEntries(spec.entries.filter(e=>e.type==="sound").map(e=>[e.key,()=>onPreview(e.key)]))});
        const r=publishOptional(store,root);return{dispose(){r.dispose();store.dispose();}};
    }});
    f.state.action("PbzMapTracker/@title");f.state.refresh();
    return {...f,store};
}
test("真实行预览事件捕获组合键，切页和遮盖取消草稿",t=>{
    const f=nativeFixture();t.after(()=>f.dispose());
    const id="PbzMapTracker/shortcut";f.state.action(id);f.state.refresh();
    let h=f.bind(id);assert.equal(h.OnPreviewKeyDown({}, {key:"K"}),"handled");assert.equal(f.store.read().values.shortcut,"Ctrl+K");
    // Refresh recycles the key-capture row; release consumption belongs to the editor, not that row instance.
    h=f.bind(id);assert.equal(h.OnKeyUp({}, {key:"K"}),"handled");
    f.state.action("PbzMapTracker/tint");f.state.refresh();f.state.edit("PbzMapTracker/tint/@channel0",1);
    f.state.cover();assert.equal(f.state.editors.colorDraft,null);assert.equal(f.store.read().values.tint,"#B02A36FF");
    f.state.resume();f.state.action(id);f.state.refresh();f.state.hide();assert.equal(f.state.editors.capturing,false);
});
test("真实颜色行能挂接预览，真实鼠标事件可绑定且不触发业务设置",t=>{
    const f=nativeFixture();t.after(()=>f.dispose());
    f.bind("PbzMapTracker/tint");assert.ok(!f.reports.some(e=>e.code==="ROW_CREATE_FAILED"));
    const id="PbzMapTracker/shortcut";f.state.action(id);f.state.refresh();const h=f.bind(id);
    assert.equal(h.OnPreviewMouseButtonDown({}, {key:"MiddleMouseButton"}),"handled");
    assert.equal(f.store.read().values.shortcut,"Ctrl+MiddleMouseButton");
});
test("真实菜单在试听启动期间关闭或被弹窗覆盖，声音立即清理",()=>{
    for(const close of [f=>f.state.hide(),f=>f.state.cover()]){
        let f,starts=0,stops=0;f=nativeFixture(()=>{starts++;close(f);return()=>stops++;});
        try{f.state.action("PbzMapTracker/sound/@preview");assert.equal(starts,1);assert.equal(stops,1);assert.equal(f.state.acceptsInput(),false);}finally{f.dispose();}
    }
});
test("键盘和手柄普通导航均可清除绑定，不需要先进入捕获",()=>{
    for(const [down,confirm] of [["Down","Enter"],["Gamepad_DPad_Down","Gamepad_FaceButton_Bottom"]]){
        const f=nativeFixture();try{
            const id="PbzMapTracker/shortcut";f.state.select(id,true);const h=f.bind(id);
            h.OnPreviewKeyDown({}, {key:down});h.OnPreviewKeyDown({}, {key:confirm});
            assert.equal(f.store.read().values.shortcut,"");assert.equal(f.state.editors.capturing,false);
        }finally{f.dispose();}
    }
});
test("禁止鼠标绑定时所有原生鼠标按钮均拒绝，第二侧键不能绕过限制",()=>{
    const f=nativeFixture(undefined,spec=>{spec.entries.find(e=>e.key==="shortcut").allowMouse=false;});
    try{
        const id="PbzMapTracker/shortcut";f.state.action(id);f.state.refresh();
        for(const key of ["LeftMouseButton","RightMouseButton","MiddleMouseButton","ThumbMouseButton","ThumbMouseButton2"]){
            const h=f.bind(id);assert.equal(h.OnPreviewMouseButtonDown({}, {key}),"handled");
            assert.equal(f.store.read().values.shortcut,"F",key);assert.equal(f.state.editors.capturing,true);
        }
    }finally{f.dispose();}
});
test("切换音效时旧音效停止回调关闭或覆盖菜单，不得启动新音效",()=>{
    for(const close of [f=>f.state.hide(),f=>f.state.cover()]){
        let f;const starts=[],stops=[];
        f=nativeFixture(key=>{starts.push(key);return()=>{stops.push(key);if(key==="sound")close(f);};},spec=>spec.entries.push({...spec.entries.find(e=>e.key==="sound"),key:"sound2"}));
        try{
            f.state.action("PbzMapTracker/sound/@preview");f.state.action("PbzMapTracker/sound2/@preview");
            assert.equal(f.state.acceptsInput(),false);assert.deepEqual(starts,["sound"]);assert.deepEqual(stops,["sound"]);
        }finally{f.dispose();}
    }
});
test("开始改键或颜色编辑时停止试听，关闭回调不得复活编辑会话",()=>{
    for(const field of ["shortcut","tint"]){
        let f;f=nativeFixture(()=>()=>f.state.hide());
        try{f.state.action("PbzMapTracker/sound/@preview");f.state.action("PbzMapTracker/"+field);assert.equal(f.state.acceptsInput(),false);assert.equal(f.state.editors.activeId,undefined);}finally{f.dispose();}
    }
});
for(const method of ["hide","cover","dispose"])test(`${method} 先关闭输入再停止声音，停止回调不能再次启动其他试听`,()=>{
    let f;const starts=[],stops=[];
    f=nativeFixture(key=>{starts.push(key);return()=>{stops.push(key);if(key==="sound")f.state.action("PbzMapTracker/sound2/@preview");};},spec=>spec.entries.push({...spec.entries.find(e=>e.key==="sound"),key:"sound2"}));
    try{
        f.state.action("PbzMapTracker/sound/@preview");f.state[method]();
        assert.equal(f.state.acceptsInput(),false);assert.deepEqual(starts,["sound"]);assert.deepEqual(stops,["sound"]);
    }finally{f.state.editors.close();f.dispose();}
});
