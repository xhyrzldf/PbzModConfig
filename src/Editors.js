"use strict";
const C = require("../provider/Controls");
const Palette = require("./ColorPalette");
// Editing state is transient. Only an explicit accepted value reaches the owner.
function createEditors(framework, options) {
    const refresh = options.refresh, word = options.word;
    const schedule = options.schedule || setTimeout, cancelTimer = options.cancel || clearTimeout;
    let session = null, playing = null, timer = null, feedback = null, previewGeneration = 0;
    const swallowed = new Set();
    function stop() {
        const generation=++previewGeneration;
        if (timer !== null) cancelTimer(timer);
        timer = null; playing = null; framework.stopPreview();
        return generation;
    }
    function cancel() { session = null; feedback = null; stop(); refresh(); }
    function error(id, result) { feedback = { id, code: Object.values(result.fields || {})[0] || result.error || "EDIT_FAILED" }; }
    function current(model, reference) {
        return model && model.enabled !== false && model.page.handle.ownerToken === reference.ownerToken && model.page.revision === reference.revision;
    }
    function reference(model) { return { id: model.id, key: model.key, handle: model.page.handle, ownerToken: model.page.handle.ownerToken, revision: model.page.revision, control: model.control }; }
    function child(model, suffix, properties) { return { ...model, id: model.id + "/@" + suffix, parentId: model.id, ...properties }; }
    function rows(model) {
        if (model.type === "keybind") {
            const capturing = session?.id === model.id && session.kind === "keybind";
            const result = [{ ...model, type: "action", editorAction: "keybind", buttonLabel: capturing ? word("pressKey") : model.displayValue }];
            // Keep clearing reachable by ordinary keyboard/controller navigation;
            // during capture those same navigation keys are the binding itself.
            if (model.control.allowUnbound !== false && model.value) result.push(child(model, "clear", {type:"action", editorAction:"clear",label:word("clearBinding"),buttonLabel:word("clearBinding")}));
            if (capturing) {
                result.push(child(model,"cancel",{type:"action",editorAction:"cancel",label:word("cancel"),buttonLabel:word("cancel")}));
            }
            return result;
        }
        if (model.type === "color") {
            const editing = session?.id === model.id && session.kind === "color", value = editing ? C.colorValue(session.channels) : model.value;
            const result = [{...model,type:"action",editorAction:"color",buttonLabel:value,colorPreview:value}];
            if (editing) {
                const labels = ["red","green","blue","alpha"];
                session.channels.forEach((value,index)=>result.push(child(model,"channel"+index,{type:"number",editorChannel:index,label:word(labels[index]),value,displayValue:String(value),min:0,max:255,step:1,minDisplayValue:"0",maxDisplayValue:"255"})));
                for(const action of ["applyColor","cancel"]) result.push(child(model,action,{type:"action",editorAction:action,label:word(action),buttonLabel:word(action)}));
            }
            return result;
        }
        if (model.type === "sound" && options.compactSound) return [{...model,type:"choice",inlineSoundPreview:true,previewPlaying:playing?.id===model.id,previewLabel:word(playing?.id===model.id?"stop":"preview")}];
        if (model.type === "sound") return [
            {...model,type:"choice"},
            child(model,"preview",{type:"action",editorAction:"preview",label:word("preview"),buttonLabel:word(playing?.id === model.id ? "stop" : "preview")})
        ];
        return [model];
    }
    function accept(value) {
        const s = session;
        if (!s) return;
        const result = framework.edit(s.handle,s.key,value,s.revision);
        if (result.ok) { session = null; feedback = null; }
        else { error(s.id,result); if (["REVISION_CONFLICT","STALE_PROVIDER","PROVIDER_FAILED","DISABLED"].includes(result.error)) session = null; }
        refresh();
    }
    return {
        rows,
        get capturing() { return session?.kind === "keybind"; },
        get activeId() { return session?.id; },
        get feedback() { return feedback; },
        get colorDraft() { return session?.kind === "color" ? C.colorValue(session.channels) : null; },
        get colorEdit() { return session?.kind === "color" ? {id:session.id,key:session.key,handle:session.handle,value:C.colorValue(session.channels),revision:session.revision} : null; },
        pickColor(value) {
            if(session?.kind!=="color"||C.colorError(session.control,value))return false;
            session.channels=C.colorChannels(value);feedback=null;refresh();return true;
        },
        setBrightness(value) { return session?.kind==="color" ? this.pickColor(Palette.brightness(C.colorValue(session.channels),value)) : false; },
        reconcile(models) {
            if (session && !current(models.get(session.id),session)) { const id=session.id;session=null;feedback={id,code:"REVISION_CONFLICT"}; }
            if (playing && !current(models.get(playing.id),playing)) stop();
        },
        select(id) {
            if (session && id !== session.id && !id.startsWith(session.id+"/@")) { session=null;feedback=null;refresh(); }
        },
        action(model) {
            if (!model.editorAction) return false;
            if (model.enabled === false) return true;
            if (model.editorAction === "cancel") { cancel(); return true; }
            if (model.editorAction === "clear") {
                if(model.control.allowUnbound!==false){
                    const result=framework.edit(model.page.handle,model.key,"",model.page.revision);
                    if(result.ok){session=null;feedback=null;}else error(model.parentId,result);
                    refresh();
                }
                return true;
            }
            if (model.editorAction === "applyColor") { if(session?.kind==="color")accept(C.colorValue(session.channels));return true; }
            if (model.editorAction === "preview") {
                if (playing?.id === model.parentId) stop();
                else {
                    const generation=stop();
                    if(generation!==previewGeneration)return true;
                    feedback=null;
                    const result=framework.preview(model.page.handle,model.key,model.page.revision,options.beginAudioFocus);
                    if(generation!==previewGeneration)return true;
                    if(result.ok){playing={...reference(model),id:model.parentId};timer=schedule(()=>{stop();refresh();},result.durationMs||5000);}
                    else error(model.parentId,result);
                }
                refresh();return true;
            }
            const generation=stop();
            if(generation!==previewGeneration)return true;
            feedback=null;
            if (session?.id === model.id) { session=null;refresh();return true; }
            session={...reference(model),kind:model.editorAction};
            if(session.kind==="color")session.channels=C.colorChannels(model.value);
            refresh();return true;
        },
        edit(model,value) {
            if(model.editorChannel === undefined)return false;
            if(session?.kind==="color" && session.id===model.parentId && Number.isInteger(value) && value>=0 && value<=255){session.channels[model.editorChannel]=value;feedback=null;refresh();}
            return true;
        },
        key(name,repeat,modifiers={}) {
            if(swallowed.has(name) && repeat)return true;
            if(!session)return false;
            if(["Escape","Gamepad_FaceButton_Right"].includes(name)){swallowed.add(name);cancel();return true;}
            if(session.kind!=="keybind")return false;
            swallowed.add(name);
            if(repeat || C.MODIFIER_KEYS.has(name))return true;
            const value=C.chord(name,/^Gamepad_/.test(name)?{}:modifiers), invalid=C.bindingError(session.control,value);
            if(invalid){feedback={id:session.id,code:invalid};refresh();return true;}
            accept(value);return true;
        },
        keyUp(name) { const owned=swallowed.delete(name);return owned || session?.kind==="keybind"; },
        close() { session=null;feedback=null;swallowed.clear();stop(); },
        cancel
    };
}
module.exports={createEditors};
