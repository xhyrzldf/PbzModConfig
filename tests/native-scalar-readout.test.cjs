"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {fixture}=require("./native-input-fixture.cjs");
const {descriptor}=require("./components-fixture.cjs");
const {memoryIO,clock}=require("./fixtures.cjs");
const {createStore}=require("../provider/ConfigStore");
const {createJournal}=require("../provider/Journal");
const {publishOptional}=require("../provider/Protocol");

function menu(io=memoryIO()){
    let store;
    const f=fixture({liveActions:true,createProvider(root){
        const spec=descriptor();spec.modId="PbzMapTracker";
        Object.assign(spec.entries.find(e=>e.key==="level"),{format:"P0",step:.01,defaultValue:.2,enabledWhen:{key:"enabled",equals:true}});
        spec.entries.push({key:"width",type:"number",label:"Width",defaultValue:600,min:360,max:800,step:20,format:"F0",group:"main"});
        store=createStore(spec,createJournal(io,spec.modId),clock());
        const registration=publishOptional(store,root);
        return{dispose(){store.dispose();registration.dispose();}};
    }});
    f.state.action(f.id);f.state.refresh();
    return Object.assign(f,{store,io,row(key){
        const id="PbzMapTracker/"+key,host=f.bind(id),binding=f.state.entries.get(id);
        f.state.select(id,false);
        return{host,binding,id};
    }});
}
function visible(r,value,selected=true){
    const row=r.binding.row,m=r.binding.state.models.get(r.binding.item);
    assert.equal(row.CurrentValue.text,value,"fixed current value must match the stored/formatted value");
    assert.equal(row.Text_SettingValue.text,value,"native cursor readout must match the fixed readout");
    assert.equal(row.CurrentValue.visibility,selected?3:1);
    assert.equal(row.Text_SettingValue.visibility,selected?1:3);
    assert.equal(row.Text_LeftValue.visibility,selected?1:3,"range endpoints appear and disappear together");
    assert.equal(row.Text_RightValue.visibility,row.Text_LeftValue.visibility);
    assert.equal(row.Text_LeftValue.text,m.minDisplayValue);
    assert.equal(row.Text_RightValue.text,m.maxDisplayValue,"right endpoint is always the maximum, never the current value");
    assert.equal(row.CurrentValue.opacity,1);assert.equal(row.Text_SettingValue.opacity,1);
}
test("百分比拖动即时显示实际步进值，结束保存后重开一致",t=>{
    const f=menu();t.after(()=>f.dispose());const r=f.row("level");visible(r,"20%");
    r.binding.control.OnValueChanged.emit(.374);visible(r,"37%");
    assert.equal(f.store.read().values.level,.37);
    assert.equal(r.binding.control.displayValue,undefined,"do not duplicate the native cursor value with an extra slider label");
    r.binding.control.OnMouseCaptureEnd.emit();assert.ok(f.io.writes>0);
    const reopened=menu(f.io);t.after(()=>reopened.dispose());visible(reopened.row("level"),"37%");
});
test("原生双状态区分当前值与范围，键盘手柄步进同步",t=>{
    const f=menu();t.after(()=>f.dispose());const r=f.row("width");visible(r,"600");
    for(const selected of [false,true]){r.host.BP_OnItemSelectionChanged(selected);visible(r,"600",selected);}
    f.state.select(r.id,false);visible(r,"600");
    r.host.OnPreviewKeyDown({},{key:"Right"});visible(r,"620");
    r.host.OnKeyUp({},{key:"Right"});
    r.host.OnPreviewKeyDown({},{key:"Gamepad_DPad_Left"});visible(r,"600");
    r.host.OnKeyUp({},{key:"Gamepad_DPad_Left"});
    r.binding.control.OnControllerCaptureEnd.emit();assert.equal(f.store.read().values.width,600);
    f.state.select("PbzMapTracker/level",false);visible(r,"600",false);
});
test("保留数值行原生逐帧定位，值更新会更新随滑块读数，回收后不接收旧输入",t=>{
    const f=menu();t.after(()=>f.dispose());const r=f.row("level"),row=r.binding.row;
    assert.equal(row.TickFrequency,1,"native cursor placement must still run after the first layout and on resize");
    const initial=row.cursorUpdates;r.binding.control.OnValueChanged.emit(.73);visible(r,"73%");
    assert.ok(row.cursorUpdates>initial);assert.equal(row.cursorNormalizedValue,.73);
    const oldControl=r.binding.control;r.host.BP_OnEntryReleased();oldControl.OnValueChanged.emit(.12);
    assert.equal(f.store.read().values.level,.73);
    visible(f.row("width"),"600");
});
test("颜色通道显示0至255实际值，禁用项不会被拖动写入",t=>{
    const f=menu();t.after(()=>f.dispose());
    f.state.action("PbzMapTracker/tint");f.state.refresh();
    const channel=f.row("tint/@channel0");visible(channel,"176");
    channel.binding.control.OnValueChanged.emit(.5);visible(channel,"128");
    const r=f.row("level");f.state.edit("PbzMapTracker/enabled",false);
    assert.equal(f.state.selected,"PbzMapTracker/enabled");
    // Changing dependencies refreshes the native list and replaces its tokens.
    // Old row input must be inert; rebind the disabled row as UMG does.
    r.binding.control.OnValueChanged.emit(.9);assert.equal(f.store.read().values.level,.2);
    const disabled=f.row("level");disabled.binding.control.OnValueChanged.emit(.9);
    visible(disabled,"20%");assert.equal(f.store.read().values.level,.2);
    assert.equal(f.reports.filter(e=>/FAILED/.test(e.code)).length,0);
});
