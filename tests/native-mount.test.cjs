"use strict";
const test = require("node:test"), assert = require("node:assert/strict");
const {createSupport} = require("../native/NativeSupport");

function mountFixture({nested = false, failAt = null, brokenRoot = false} = {}) {
    const created = [], reports = [], original = new Error("synthetic layout copy failure");
    function node(kind, name) {
        return {kind, name, parent:null, removals:0, Slot:{}, IsA(type) {return type === kind;}, GetParent() {return this.parent;},
            AddChild(child) {child.parent=this;return {SetPadding() {if (child.name === failAt) throw original;}};},
            RemoveFromParent() {this.removals++;if (brokenRoot && this === root()) throw Error("access a invalid object");this.parent=null;}};
    }
    const switcher=node("WidgetSwitcher", "switcher"), nativePage=node("Overlay", "nativePage"), nativeDetailsParent=node("Overlay", "nativeDetailsParent");
    nativePage.parent=switcher;nativeDetailsParent.parent=nested?nativePage:null;
    const sourceList=node("ListView", "sourceList"), sourceDetails=node("Details", "sourceDetails");
    sourceList.parent=nested?nativePage:switcher;sourceDetails.parent=nativeDetailsParent;
    sourceList.Slot={Padding:0};sourceDetails.Slot={Padding:0};
    const list=node("ListView", "list"), details=node("Details", "details");
    const root=()=>nested?created[0]:list;
    const UE={KismetSystemLibrary:{IsValid:value=>!!value},NewObject(type) {const copy=node(type,"copy"+created.length);created.push(copy);return copy;}};
    for (const name of ["CanvasPanel", "Overlay", "SizeBox", "ContentWidget"]) UE[name]={StaticClass:()=>name};
    const owner={WidgetSwitcher_65:switcher,ListView_Settings:sourceList,Details_Settings:sourceDetails,WidgetTree:{}};
    return {ui:createSupport(UE,e=>reports.push(e)),owner,list,details,root,created,reports,original,sourceList,sourceDetails};
}

for (const nested of [false,true]) test(`failed detail mount cleans independent owners and preserves the original error (nested=${nested})`, () => {
    const x=mountFixture({nested,failAt:"details",brokenRoot:true});
    let caught;
    try {x.ui.mount(x.owner,x.list,x.details);} catch(error) {caught=error;}
    assert.equal(x.details.removals,1,"a failed root removal must not skip details");
    assert.equal(x.details.parent,null);
    for (const copy of x.created.slice(1)) assert.equal(copy.removals,1,"intermediate copies must also be cleaned");
    assert.equal(caught,x.original,"cleanup must not replace the initiating error");
    assert.equal(x.sourceList.removals,0);assert.equal(x.sourceDetails.removals,0);
});

test("a list slot failure before details are mounted still removes the newly attached root", () => {
    const x=mountFixture({failAt:"list"});
    assert.throws(()=>x.ui.mount(x.owner,x.list,x.details),e=>e===x.original);
    assert.equal(x.list.parent,null);assert.equal(x.list.removals,1);
    assert.equal(x.sourceList.removals,0);assert.equal(x.sourceDetails.removals,0);
});

for (const nested of [false,true]) test(`successful native mount retains its owned layout (nested=${nested})`, () => {
    const x=mountFixture({nested});const layout=x.ui.mount(x.owner,x.list,x.details);
    assert.equal(layout.root,x.root());assert.equal(layout.root.parent,x.owner.WidgetSwitcher_65);
    assert.ok(x.details.parent);assert.equal(x.details.removals,0);
    assert.equal(layout.external,!nested);
});
