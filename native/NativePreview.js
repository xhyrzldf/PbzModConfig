"use strict";
const Palette=require("../src/ColorPalette");
const {colorChannels}=require("../provider/Controls");
// Uses only widgets owned by this menu. Provider previews are isolated from configuration writes.
function createPreviewPane(UE,ui,state,framework,report){
    let pane=null,canvas=null,host=null,wheel=null,marker=null,swatches=[],labels=[],caption=null,controller=null,ownerToken=null,failedToken=null,dead=false;
    const scope=ui.lifetime(),W=520,S=180;
    const linear=x=>{x/=255;return x<=.04045?x/12.92:Math.pow((x+.055)/1.055,2.4);};
    function place(parent,widget,x,y,w,h){const s=parent.AddChildToCanvas(widget);s.SetPosition(new UE.Vector2D(x,y));s.SetSize(new UE.Vector2D(w,h));return s;}
    function release(){const old=controller;controller=null;ownerToken=null;if(old)old.dispose();}
    function ensure(){
        if(pane)return;
        const box=state.detailView.Box_DetailsExtension;if(!ui.valid(box))throw Error("PREVIEW_EXTENSION_MISSING");
        pane=ui.native(state.detailView,"SizeBox");pane.SetWidthOverride(W);pane.SetHeightOverride(300);
        box.AddChild(pane);scope.own(()=>pane.RemoveFromParent());
        canvas=ui.native(state.detailView,"CanvasPanel");pane.SetContent(canvas);
        host=ui.native(state.detailView,"Overlay");place(canvas,host,0,0,1040,585);
        host.SetRenderTransformPivot(new UE.Vector2D(0,0));host.SetRenderScale(new UE.Vector2D(.5,.5));
        host.SetVisibility(ui.V.HitTestInvisible);
        caption=label("",0,278,500);
    }
    function label(value,x,y,w){const text=ui.native(state.detailView,state.detailView.Text_SettingName.GetClass());
        const font=state.detailView.Text_SettingName.Font;if(font){text.SetFont(font);}
        ui.text(text,value);text.SetVisibility(ui.V.HitTestInvisible);place(canvas,text,x,y,w,28);return text;}
    function colorImage(parent,x,y,w,h){
        const image=ui.native(state.detailView,"Image");image.SetBrushFromTexture(UE.Object.Load("/Engine/EngineResources/WhiteSquareTexture.WhiteSquareTexture"),false);
        image.SetVisibility(ui.V.HitTestInvisible);place(parent,image,x,y,w,h);return image;
    }
    function ensureWheel(){
        if(wheel)return;
        const path=UE.BlueprintPathsLibrary.ProjectContentDir()+"JavaScript/PbzModConfig/assets/color-wheel.png";
        const texture=UE.KismetRenderingLibrary.ImportFileAsTexture2D(state.panel,path);if(!ui.valid(texture))throw Error("PALETTE_TEXTURE_UNAVAILABLE");
        wheel=ui.native(state.detailView,"Border");wheel.SetPadding(new UE.Margin());
        wheel.SetBrushColor(new UE.LinearColor(0,0,0,0));place(canvas,wheel,0,300,S,S);
        const art=ui.native(state.detailView,"Image");art.SetBrushFromTexture(texture,false);art.SetVisibility(ui.V.HitTestInvisible);wheel.SetContent(art);
        marker=colorImage(canvas,0,300,8,8);marker.SetColorAndOpacity(new UE.LinearColor(1,1,1,1));
        swatches=[colorImage(canvas,210,320,64,48),colorImage(canvas,286,320,64,48)];
        labels=[label(state.word("colorBefore"),210,290,76),label(state.word("colorAfter"),286,290,100)];
        const choose=(geometry,event)=>{
            if(dead||!state.acceptsInput()||!state.editors.colorEdit||String(UE.KismetInputLibrary.PointerEvent_GetEffectingButton(event).KeyName)!=="LeftMouseButton")return UE.WidgetBlueprintLibrary.Unhandled();
            try{
                const p=UE.SlateBlueprintLibrary.AbsoluteToLocal(geometry,UE.KismetInputLibrary.PointerEvent_GetScreenSpacePosition(event));
                const value=Palette.wheel(state.editors.colorDraft,p.X,p.Y,S);
                if(value)state.editors.pickColor(value);
            }catch(e){report({code:"COLOR_PALETTE_INPUT_FAILED",detail:String(e)});}
            return UE.WidgetBlueprintLibrary.Handled();
        };
        wheel.OnMouseButtonDownEvent.Bind(choose);scope.own(()=>wheel.OnMouseButtonDownEvent.Unbind());
    }
    function hide(){release();if(pane)pane.SetVisibility(ui.V.Collapsed);}
    return {
        update(model){
            if(dead||!state.acceptsInput()){hide();return;}
            const edit=state.editors.colorEdit,handle=model?.page?.handle,showVisual=!!handle&&framework.hasVisual(handle)&&!model.section;
            if(!edit&&!showVisual){hide();return;}
            try{
                ensure();pane.SetVisibility(ui.V.SelfHitTestInvisible);state.detailView.Box_DetailsExtension.SetVisibility(ui.V.SelfHitTestInvisible);
                const colorY=showVisual?310:0;pane.SetHeightOverride(edit?colorY+190:310);
                if(showVisual){
                    host.SetVisibility(ui.V.HitTestInvisible);
                    if(ownerToken!==handle.ownerToken){release();if(failedToken!==handle.ownerToken){const r=framework.openVisual(handle,{owner:state.panel,host,width:1040,height:585,setCaption:value=>ui.text(caption,value),report:error=>report({code:"PROVIDER_PREVIEW_FAILED",detail:String(error)})});if(r.ok){controller=r;ownerToken=handle.ownerToken;}else failedToken=handle.ownerToken;}}
                    const key=edit?.key||model.key;
                    if(controller&&!controller.update(key,edit)){release();failedToken=handle.ownerToken;}
                }else{release();host.SetVisibility(ui.V.Collapsed);}
                caption.SetVisibility(showVisual?ui.V.HitTestInvisible:ui.V.Collapsed);
                if(edit){
                    ensureWheel();wheel.SetVisibility(ui.V.Visible);marker.SetVisibility(ui.V.HitTestInvisible);
                    wheel.Slot.SetPosition(new UE.Vector2D(0,colorY));
                    const p=Palette.marker(edit.value,S);marker.Slot.SetPosition(new UE.Vector2D(p.x-4,p.y+colorY-4));
                    labels.forEach((w,i)=>{ui.text(w,state.word(i?"colorAfter":"colorBefore"));w.Slot.SetPosition(new UE.Vector2D(210+i*76,colorY+8));w.SetVisibility(ui.V.HitTestInvisible);});
                    swatches.forEach((w,i)=>w.Slot.SetPosition(new UE.Vector2D(210+i*76,colorY+40)));
                    const before=model.page.values[edit.key];[before,edit.value].forEach((hex,i)=>{const c=colorChannels(hex);swatches[i].SetColorAndOpacity(new UE.LinearColor(...c.slice(0,3).map(linear),(c[3]??255)/255));swatches[i].SetVisibility(ui.V.HitTestInvisible);});
                }else if(wheel){wheel.SetVisibility(ui.V.Collapsed);marker.SetVisibility(ui.V.Collapsed);[...swatches,...labels].forEach(w=>w.SetVisibility(ui.V.Collapsed));}
            }catch(e){hide();report({code:"PREVIEW_PANE_FAILED",detail:String(e)});}
        },
        hide,
        dispose(){if(dead)return;dead=true;hide();scope.dispose();}
    };
}
module.exports={createPreviewPane};
