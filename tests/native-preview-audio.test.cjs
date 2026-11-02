"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const {begin}=require("../native/NativePreviewAudio");
const {setup}=require("./components-fixture.cjs");
const {publishOptional}=require("../provider/Protocol");
function fixture(){
    const calls=[],reports=[],settings={MusicVolume:.7,AmbientVolume:.4};let fail=null;
    const UE={PBZBlueprintFunctionLibrary:{GetLocalPlayer:()=>({GetSharedSettings:()=>settings})},EAudioVolumeType:{MusicVolume:2,AmbVolume:5},
        PBZSoundFXSubsystem:{StaticClass:()=>1},SubsystemBlueprintLibrary:{GetWorldSubsystem:()=>({SetAudioVolume:(channel,value)=>{calls.push([channel,value]);if(fail?.(channel,value))throw Error("mix-write-failed");}})}};
    return {UE,calls,reports,settings,start:()=>begin(UE,{},e=>reports.push(e)),fail:fn=>fail=fn};
}
test("试听仅压低音乐与环境音，恢复实时偏好，不修改设置或停止原生声音",()=>{
    const f=fixture(),stop=f.start();assert.deepEqual(f.calls,[[2,.7*.2],[5,.4*.2]]);assert.deepEqual(f.settings,{MusicVolume:.7,AmbientVolume:.4});
    f.settings.MusicVolume=.3;stop();stop();assert.deepEqual(f.calls.slice(2),[[5,.4],[2,.3]]);
    assert.equal(f.reports.filter(e=>e.stage==="restored").length,2);
});
test("未知音量范围不改混音；第二个通道失败也恢复第一个，恢复失败有明确日志",()=>{
    const invalid=fixture();invalid.settings.AmbientVolume=50;invalid.start()();assert.deepEqual(invalid.calls,[]);assert.equal(invalid.reports.at(-1).stage,"unavailable");
    const f=fixture();f.fail((c,v)=>c===5&&v<.2);f.start()();assert.deepEqual(f.calls,[[2,.7*.2],[5,.4*.2],[5,.4],[2,.7]]);
    const g=fixture(),stop=g.start();g.fail(c=>c===5);stop();assert.ok(g.reports.some(e=>e.stage==="restore_failed"));assert.deepEqual(g.calls.at(-1),[2,.7]);
});
test("旧试听停止回调中开启新试听，不会被旧回调恢复音量；最后一个结束才恢复",()=>{
    const f=fixture(),old=f.start(),next=f.start();assert.equal(f.calls.length,2);
    old();assert.equal(f.calls.length,2);next();assert.deepEqual(f.calls.slice(2),[[5,.4],[2,.7]]);old();next();assert.equal(f.calls.length,4);
});
test("框架统一持有试听音量：拒绝、抛错、切换、注销和停止失败都恢复一次",()=>{
    for(const mode of ["reject","throw","normal","stop-throws","reentrant"]){
        const x=setup(),events=[];let restored=0,stopped=0,raised=0;
        const reg=publishOptional({...x.store,previewSound:()=>{
            if(mode==="reject")return{ok:false,error:"UNAVAILABLE"};if(mode==="throw")throw Error("post-failed");
            if(mode==="reentrant")x.framework.stopPreview();
            return{ok:true,durationMs:500,stop(){stopped++;if(mode==="stop-throws")throw Error("stop-failed");}};
        }},x.root);
        try{
            const p=x.page(),focus=()=>{raised++;events.push("lower");return()=>{restored++;events.push("restore");}};
            const result=x.framework.preview(p.handle,"sound",p.revision,focus);
            if(mode==="normal"||mode==="stop-throws")assert.equal(result.ok,true);else assert.equal(result.ok,false);
            reg.dispose();x.framework.stopPreview();assert.equal(raised,1);assert.equal(restored,1);assert.deepEqual(events,["lower","restore"]);
            assert.equal(stopped,["normal","stop-throws","reentrant"].includes(mode)?1:0);
        }finally{reg.dispose();x.dispose();}
    }
});
