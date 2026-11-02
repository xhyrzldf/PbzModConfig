"use strict";
// One gate owns each physical axis. Analog events and their synthetic keys
// share a state; a neutral horizontal sample never releases vertical input.
const keys={
    Up:["keyboard","y",-1],W:["keyboard","y",-1],Down:["keyboard","y",1],S:["keyboard","y",1],
    Left:["keyboard","x",-1],A:["keyboard","x",-1],Right:["keyboard","x",1],D:["keyboard","x",1],
    Gamepad_DPad_Up:["pad","y",-1],Gamepad_DPad_Down:["pad","y",1],Gamepad_DPad_Left:["pad","x",-1],Gamepad_DPad_Right:["pad","x",1],
    Gamepad_LeftStick_Up:["stick","y",-1],Gamepad_LeftStick_Down:["stick","y",1],Gamepad_LeftStick_Left:["stick","x",-1],Gamepad_LeftStick_Right:["stick","x",1]
};
const INITIAL_MS=380,REPEAT_MS=180,LIGHT_REPEAT_MS=260,ENTER=.6,RELEASE=.28,ANALOG_LEASE_MS=500;
function createNavigation(options={}){
    const now=options.now||Date.now,held=new Map(),analogSeen=new Map();
    let stats={keyEvents:0,axisEvents:0,accepted:0,suppressed:0};
    const result=(axis,delta,fire)=>{stats[fire?"accepted":"suppressed"]++;return {kind:axis==="y"?"move":"step",delta,fire};};
    function press(device,axis,delta,pressure=1){
        const t=now(),id=device+axis,previous=held.get(id);
        if(!previous||previous.delta!==delta||t<previous.last){held.set(id,{delta,last:t,next:t+INITIAL_MS});return result(axis,delta,true);}
        if(t<previous.next)return result(axis,delta,false);
        previous.last=t;previous.next=t+(pressure<.85?LIGHT_REPEAT_MS:REPEAT_MS);
        return result(axis,delta,true); // Never catch up missed repeats after a slow frame.
    }
    return {
        key(name){
            const k=keys[name];if(!k)return null;stats.keyEvents++;
            const [device,axis,delta]=k,last=analogSeen.get(axis),t=now();
            if(device==="stick"&&last!==undefined&&t>=last&&t-last<ANALOG_LEASE_MS)return result(axis,delta,false);
            return press(device,axis,delta);
        },
        keyUp(name){
            const k=keys[name];if(!k)return false;
            const [device,axis,delta]=k,last=analogSeen.get(axis),t=now();
            if(device==="stick"&&last!==undefined&&t>=last&&t-last<ANALOG_LEASE_MS)return true;
            if(held.get(device+axis)?.delta===delta)held.delete(device+axis);
            return true;
        },
        analog(name,value){
            const axis=name==="Gamepad_LeftX"?"x":name==="Gamepad_LeftY"?"y":null;if(!axis)return null;
            stats.axisEvents++;if(!Number.isFinite(value))return result(axis,0,false);
            const t=now(),id="stick"+axis,previous=held.get(id),pressure=Math.abs(value),delta=(axis==="y"?-1:1)*Math.sign(value);
            analogSeen.set(axis,t);
            if(pressure<RELEASE){held.delete(id);return result(axis,0,false);}
            if(pressure<ENTER&&(!previous||previous.delta!==delta))return result(axis,delta,false);
            return press("stick",axis,delta,pressure);
        },
        reset(){held.clear();analogSeen.clear();},
        inspect(){return {...stats,initialMs:INITIAL_MS,repeatMs:REPEAT_MS,lightRepeatMs:LIGHT_REPEAT_MS,enter:ENTER,release:RELEASE};},
        flush(){const result=this.inspect();stats={keyEvents:0,axisEvents:0,accepted:0,suppressed:0};this.reset();return result;}
    };
}
module.exports={createNavigation};
