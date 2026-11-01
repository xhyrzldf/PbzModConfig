"use strict";
const {createStore}=require("../provider/ConfigStore");
const {createJournal}=require("../provider/Journal");
const {descriptor}=require("./components-fixture.cjs");
const {fileIO}=require("./fixtures.cjs");
const [directory,mode]=process.argv.slice(2);
const store=createStore(descriptor(),createJournal(fileIO(directory,"Components"),"Components"));
if(mode==="write"){
    if(!store.apply({enabled:false,level:0.7,shortcut:"Ctrl+Shift+K",tint:"#12345678",sound:"tick"}).ok || !store.flush().ok)process.exitCode=1;
}
process.stdout.write(JSON.stringify(store.read()));
store.dispose();
