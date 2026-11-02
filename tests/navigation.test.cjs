"use strict";
const test=require('node:test'),assert=require('node:assert/strict');
const {createNavigation}=require('../src/Navigation'),{fixture}=require('./native-input-fixture.cjs');
test('30至240帧的成对摇杆采样和虚拟按键，不把每帧当成一次上下移动',()=>{
    for(const fps of [30,60,126,240]){
        let time=0;const n=createNavigation({now:()=>time}),accepted=[];
        for(let frame=0;frame<fps*2;frame++){
            time=frame*1000/fps;
            for(const r of [n.analog('Gamepad_LeftX',0),n.key('Gamepad_LeftStick_Down'),n.analog('Gamepad_LeftY',-1)])if(r.fire)accepted.push(time);
        }
        assert.equal(accepted[0],0);assert.ok(accepted[1]>=380);assert.ok(accepted.length>=8&&accepted.length<=10,`${fps}: ${accepted}`);
        for(let i=2;i<accepted.length;i++)assert.ok(accepted[i]-accepted[i-1]>=180-1e-8);
        n.analog('Gamepad_LeftY',0);time+=1;assert.equal(n.key('Gamepad_LeftStick_Down').fire,false,'回零后残留虚拟按键不多走一行');
    }
});
test('首拨立即、短拨再按立即；长按有等待，反向和卡帧不补发旧步数',()=>{
    let time=0;const n=createNavigation({now:()=>time});
    assert.equal(n.key('Gamepad_DPad_Down').fire,true);time=100;assert.equal(n.key('Gamepad_DPad_Down').fire,false);
    n.keyUp('Gamepad_DPad_Down');assert.equal(n.key('Gamepad_DPad_Down').fire,true);
    time=479;assert.equal(n.key('Gamepad_DPad_Down').fire,false);time=480;assert.equal(n.key('Gamepad_DPad_Down').fire,true);
    assert.equal(n.key('Gamepad_DPad_Up').fire,true);time=2000;assert.equal(n.key('Gamepad_DPad_Up').fire,true);assert.equal(n.key('Gamepad_DPad_Up').fire,false);
    n.reset();assert.equal(n.key('Gamepad_DPad_Up').fire,true);
});
test('死区有回滞，另一轴回零不重置；轻拨重复更慢，方向键来源与真实按键释放独立',()=>{
    let time=0;const n=createNavigation({now:()=>time});
    assert.equal(n.analog('Gamepad_LeftY',.59).fire,false);assert.equal(n.analog('Gamepad_LeftY',.7).fire,true);
    time=100;n.analog('Gamepad_LeftX',0);assert.equal(n.analog('Gamepad_LeftY',.4).fire,false);
    time=380;assert.equal(n.analog('Gamepad_LeftY',.7).fire,true);time=560;assert.equal(n.analog('Gamepad_LeftY',.7).fire,false);
    time=640;assert.equal(n.analog('Gamepad_LeftY',.7).fire,true);
    n.analog('Gamepad_LeftY',.1);time=641;assert.equal(n.analog('Gamepad_LeftY',.7).fire,true);
    assert.equal(n.key('Down').fire,true);assert.equal(n.key('Down').fire,false);n.keyUp('Down');assert.equal(n.key('Down').fire,true);
    assert.equal(n.analog('Gamepad_RightY',1),null);assert.equal(n.key('Z'),null);
});
test('真实行的KeyUp释放、菜单覆盖与关闭都重置节奏，不触碰原生页签按键',()=>{
    let time=0;const f=fixture({now:()=>time});try{
        f.analog('Gamepad_LeftX',0);f.analog('Gamepad_LeftY',-1);time=10;f.analog('Gamepad_LeftX',0);f.analog('Gamepad_LeftY',-1);
        assert.equal(f.calls.filter(c=>c[0]==='move').length,1);
        f.key('Gamepad_LeftStick_Down');assert.equal(f.calls.filter(c=>c[0]==='move').length,1);
        assert.equal(f.host.OnKeyUp({}, {key:'Gamepad_DPad_Down'}),'handled');
        f.key('Down');f.host.OnKeyUp({}, {key:'Down'});f.key('Down');assert.equal(f.calls.filter(c=>c[0]==='move').length,3);
        f.state.cover();f.state.resume();f.analog('Gamepad_LeftY',-1);assert.equal(f.calls.filter(c=>c[0]==='move').length,4);
        assert.equal(f.key('Gamepad_LeftShoulder'),'unhandled');f.state.hide();assert.ok(f.reports.some(e=>e.code==='NAVIGATION_SUMMARY'&&e.accepted===4));
    }finally{f.dispose();}
});
