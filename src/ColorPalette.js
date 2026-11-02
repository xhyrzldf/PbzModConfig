"use strict";
const {colorChannels,colorValue}=require("../provider/Controls");
const clamp=x=>Math.max(0,Math.min(1,x));
function hsv(hex){
    const rgb=colorChannels(hex).slice(0,3).map(x=>x/255),max=Math.max(...rgb),min=Math.min(...rgb),d=max-min;
    let h=0;if(d){const i=rgb.indexOf(max);h=60*(i===0?(rgb[1]-rgb[2])/d:i===1?(rgb[2]-rgb[0])/d+2:(rgb[0]-rgb[1])/d+4);}
    return {h:(h+360)%360,s:max?d/max:0,v:max};
}
function rgb(h,s,v){
    h=((h%360)+360)%360;s=clamp(s);v=clamp(v);
    const c=v*s,x=c*(1-Math.abs((h/60)%2-1)),m=v-c;
    const values=[[c,x,0],[x,c,0],[0,c,x],[0,x,c],[x,0,c],[c,0,x]][Math.floor(h/60)];
    return values.map(a=>Math.round((a+m)*255));
}
function wheel(hex,x,y,size){
    if(![x,y,size].every(Number.isFinite)||size<=0)return null;
    const dx=x-size/2,dy=size/2-y,r=Math.hypot(dx,dy)/(size/2);
    if(r>1)return null;
    const channels=colorChannels(hex),current=hsv(hex);
    // A black starting color must still let the player see the color they pick.
    return colorValue([...rgb(Math.atan2(dy,dx)*180/Math.PI,r,current.v||1),...channels.slice(3)]);
}
function marker(hex,size){const {h,s}=hsv(hex),angle=h*Math.PI/180;return {x:size/2+Math.cos(angle)*s*size/2,y:size/2-Math.sin(angle)*s*size/2};}
function brightness(hex,value){const channels=colorChannels(hex),c=hsv(hex);return colorValue([...rgb(c.h,c.s,clamp(value)),...channels.slice(3)]);}
module.exports={hsv,rgb,wheel,marker,brightness};
