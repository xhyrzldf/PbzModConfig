"use strict";
// Copy provider/ into your mod's private namespace. This example is not shipped.
const {createStore}=require("../provider/ConfigStore");
const {createJournal}=require("../provider/Journal");
const {publishOptional}=require("../provider/Protocol");
function descriptor(modId="PbzExtendedDemo") {
    return {
        apiVersion:1,modId,modVersion:"1.0.0",schemaVersion:1,
        displayName:{en:"Component example",zhHans:"组件示例"},groups:[],
        entries:[
            {key:"enabled",type:"toggle",label:{en:"Enabled",zhHans:"启用"},defaultValue:true},
            {key:"shortcut",type:"keybind",label:{en:"Toggle display",zhHans:"切换显示"},defaultValue:"Ctrl+G",
                allowModifiers:true,allowGamepad:true,allowMouse:true,allowUnbound:true,
                reservedKeys:["Z","C"],conflictGroup:"display"},
            {key:"tint",type:"color",label:{en:"Marker color",zhHans:"标记颜色"},alpha:true,defaultValue:"#E4C887FF"},
            {key:"sound",type:"sound",label:{en:"Notification sound",zhHans:"提示音"},defaultValue:"bell",
                enabledWhen:{key:"enabled",equals:true},
                options:[{value:"bell",label:{en:"Bell",zhHans:"铃声"}},{value:"tick",label:{en:"Tick",zhHans:"轻响"}}]},
            {key:"volume",type:"number",label:{en:"Volume",zhHans:"音量"},defaultValue:0.6,min:0,max:1,step:0.05,format:"P0"}
        ]
    };
}
// playSound(id, volume) must start a short preview and return a synchronous stop
// function. Own the audio component in the business mod; never save it in values.
function createExtended(io,playSound,options={}) {
    if(typeof playSound!=="function")throw Error("PLAY_SOUND_REQUIRED");
    const spec=descriptor(options.modId);
    const store=createStore(spec,createJournal(io,spec.modId,options.report),{
        ...options,sounds:{sound:id=>playSound(id,store.read().values.volume)}
    });
    const registration=publishOptional(store,options.root||globalThis,options.report);
    return {store,registration,dispose(){const result=store.dispose();if(result.ok)registration.dispose();return result;}};
}
module.exports={descriptor,createExtended};
