"use strict";
const { createStore }=require("../provider/ConfigStore");
const { createJournal }=require("../provider/Journal");
const { getHub,publishOptional }=require("../provider/Protocol");
const { createFramework }=require("../src/Framework");
const { memoryIO,clock }=require("./fixtures.cjs");
const legacy={...require("./legacy-v1/provider/Protocol"),...require("./legacy-v1/provider/ConfigStore"),...require("./legacy-v1/src/Framework")};
function descriptor() { return { apiVersion: 1, modId: "Components", schemaVersion: 1, displayName: "Components", groups: [{ id: "main", label: "Main" }], entries: [
    {key:"enabled", type:"toggle", label:"Enabled", defaultValue:true, group:"main"},
    {key:"level", type:"number", label:"Level", defaultValue:0.5, min:0,max:1,step:0.1, group:"main"},
    {key:"mode", type:"choice", label:"Mode", defaultValue:"a", options:[{value:"a",label:"A"},{value:"b",label:"B"}]},
    {key:"shortcut", type:"keybind", label:"Shortcut", defaultValue:"F",group:"main"},
    {key:"alternate", type:"keybind", label:"Other shortcut", defaultValue:"Ctrl+G",group:"main"},
    {key:"tint", type:"color", label:"Tint", defaultValue:"#B02A36FF",alpha:true,group:"main"},
    {key:"sound", type:"sound", label:"Sound", defaultValue:"bell", options:[{value:"bell",label:"Bell"},{value:"tick",label:"Tick"}],enabledWhen:{key:"enabled",equals:true}},
    {key:"dependent", type:"toggle", label:"Dependent", defaultValue:false,visibleWhen:{key:"tint",equals:"#B02A36FF"}},
    {key:"nested", type:"toggle", label:"Nested", defaultValue:false,enabledWhen:{key:"dependent",equals:true}},
    {key:"save",type:"action",label:"Save"}
] }; }
function setup(options={}) {
    const root={}, io=options.io||memoryIO(), timer=clock(), events=[];
    const store=createStore(options.spec||descriptor(),createJournal(io,"Components"),{...timer,report:e=>events.push(e),actions:{save:({flush})=>flush()},sounds:options.sounds});
    const hub=(options.oldHub?legacy.getHub:getHub)(root);
    const registration=publishOptional(store,root,e=>events.push(e));
    const framework=(options.oldFramework?legacy.createFramework:createFramework)(hub,{report:e=>events.push(e)});
    return {root,io,timer,events,store,hub,registration,framework,page:()=>framework.pages()[0],dispose(){framework.dispose();registration.dispose();store.dispose();}};
}
module.exports={descriptor,setup};
