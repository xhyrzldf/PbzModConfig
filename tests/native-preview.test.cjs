"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {createPreviewPane}=require('../native/NativePreview'),{createEditors}=require('../src/Editors'),{setup}=require('./components-fixture.cjs');
function fixture(){
    const widgets=[],releases=[],x=setup(),events=[];
    class Vector{constructor(X,Y){Object.assign(this,{X,Y});}}
    class Color{constructor(R,G,B,A){Object.assign(this,{R,G,B,A});}}
    class Widget{
        constructor(type){this.type=type;this.children=[];this.Font={FontObject:'native-brush-font'};this.OnMouseButtonDownEvent={Bind:fn=>this.click=fn,Unbind:()=>this.click=null};widgets.push(this);}
        GetClass(){return this.type;}SetFont(f){this.Font=f;}SetWidthOverride(v){this.width=v;}SetHeightOverride(v){this.height=v;}
        AddChild(w){this.children.push(w);return w.Slot={SetPosition:p=>w.position=p,SetSize:s=>w.size=s};}AddChildToCanvas(w){return this.AddChild(w);}
        SetContent(w){this.content=w;}SetRenderTransformPivot(){}SetRenderScale(v){this.scale=v;}SetVisibility(v){this.visibility=v;}
        SetBrushFromTexture(t){this.texture=t;}SetColorAndOpacity(c){this.color=c;}SetBrushColor(){}SetPadding(){}RemoveFromParent(){this.removed=true;}
    }
    const state={panel:{},detailView:{Box_DetailsExtension:new Widget('extension'),Text_SettingName:new Widget('native-text')},acceptsInput:()=>true,word:k=>k};
    state.editors=createEditors(x.framework,{word:k=>k,refresh(){}});
    const ui={V:{Visible:1,HitTestInvisible:2,SelfHitTestInvisible:3,Collapsed:0},valid:obj=>!!obj,native:(o,t)=>new Widget(t),text:(w,s)=>w.text=s,lifetime:()=>({own:fn=>releases.push(fn),dispose(){for(const fn of releases.splice(0).reverse())fn();}})};
    const UE={Vector2D:Vector,LinearColor:Color,Margin:class{},Object:{Load:p=>p},BlueprintPathsLibrary:{ProjectContentDir:()=>'/Content/'},KismetRenderingLibrary:{ImportFileAsTexture2D:(o,p)=>({path:p})},
        SlateBlueprintLibrary:{AbsoluteToLocal:(g,p)=>({X:p.X-g.X,Y:p.Y-g.Y})},KismetInputLibrary:{PointerEvent_GetEffectingButton:e=>({KeyName:e.key}),PointerEvent_GetScreenSpacePosition:e=>e.position},WidgetBlueprintLibrary:{Handled:()=>true,Unhandled:()=>false}};
    const pane=createPreviewPane(UE,ui,state,x.framework,e=>events.push(e)),p=x.page(),model={...p.rows.find(r=>r.key==='tint'),page:p};
    return {...x,state,pane,model,widgets,events,close(){pane.dispose();state.editors.close();x.dispose();}};
}
test('原生形状的右侧调色盘使用局部坐标，选择只更新草稿，关闭解除委托和自有控件',()=>{
    const f=fixture();try{
        const before=f.store.read();f.state.editors.action(f.state.editors.rows(f.model)[0]);f.pane.update(f.model);
        const wheel=f.widgets.find(w=>w.type==='Border'),box=f.widgets.find(w=>w.type==='SizeBox');assert.ok(wheel.click);assert.equal(box.height,190);
        assert.equal(wheel.click({X:40,Y:70},{key:'LeftMouseButton',position:{X:220,Y:160}}),true);
        assert.equal(f.state.editors.colorDraft,'#B00000FF');assert.deepEqual(f.store.read(),before);
        f.pane.update(f.model);assert.equal(f.events.length,0);assert.equal(f.widgets.filter(w=>w.type==='native-text').at(-1).Font.FontObject,'native-brush-font');
        f.pane.dispose();assert.equal(wheel.click,null);assert.equal(box.removed,true);
    }finally{f.close();}
});
test('无预览扩展的旧提供者不会创建面板，菜单遮盖后不接收颜色点击',()=>{
    const f=fixture();try{
        f.pane.update(f.model);assert.equal(f.widgets.some(w=>w.type==='SizeBox'),false);
        f.state.editors.action(f.state.editors.rows(f.model)[0]);f.pane.update(f.model);const wheel=f.widgets.find(w=>w.type==='Border');
        f.state.acceptsInput=()=>false;const before=f.state.editors.colorDraft;
        assert.equal(wheel.click({X:0,Y:0},{key:'LeftMouseButton',position:{X:180,Y:90}}),false);assert.equal(f.state.editors.colorDraft,before);f.pane.hide();
        assert.equal(f.widgets.find(w=>w.type==='SizeBox').visibility,0);
    }finally{f.close();}
});
