"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const {fixture}=require("./native-input-fixture.cjs");
const {gameLanguage}=require("../src/Localization");
const {catalogs,signatures,regionalSignatures}=require("../src/LocaleStrings");
test("主播模式中西语地区由第二个原生词条区分",()=>{
    for(const locale of ["es-ES","es-419"]){
        const UE={KismetTextLibrary:{Conv_TextToString:value=>value},
            KismetInternationalizationLibrary:{GetCurrentLanguage:()=>"en-US"},
            PBZBlueprintFunctionLibrary:{MakeTextByKey:key=>key===regionalSignatures.key?regionalSignatures.values[locale]:signatures[locale]}};
        assert.equal(gameLanguage(UE,"ko"),locale);
    }
});
test("八语在实际配置页刷新且西语保留地区",t=>{
    const options={engineLanguage:"en",menuText:"NEW GAME"},f=fixture(options);t.after(()=>f.dispose());
    for(const locale of Object.keys(catalogs)){
        options.menuText=signatures[locale];options.engineLanguage=locale;f.state.refresh();
        assert.equal(f.state.locale,locale);assert.equal(f.state.word("tab"),catalogs[locale].tab);
        assert.equal(f.state.word("on"),catalogs[locale].on);assert.equal(f.state.word("confirm"),catalogs[locale].confirm);
    }
    options.menuText=signatures["es-419"];options.engineLanguage="es-MX";f.state.refresh();assert.equal(f.state.locale,"es-419");
    options.engineLanguage="";f.state.refresh();assert.equal(f.state.locale,"es-419");
});
test("主播模式式语言分离仍按原生中文刷新整个配置页",t=>{
    const options={engineLanguage:"en",menuText:"新游戏"},f=fixture(options);t.after(()=>f.dispose());
    assert.equal(f.state.locale,"zhHans");assert.equal(f.state.word("on"),"开启");
    assert.equal(f.state.word("tab"),"模组");
    options.menuText="NEW GAME";options.engineLanguage="zh-Hans";f.state.refresh();
    assert.equal(f.state.locale,"en");assert.equal(f.state.word("on"),"On");
});
test("模组标题与分组标题在实际行绑定时强制左对齐",t=>{
    const f=fixture({engineLanguage:"en",menuText:"新游戏"});t.after(()=>f.dispose());
    for(const entry of [f.state.entries.get(f.id),f.bindHeader()]){
        assert.ok(entry);assert.equal(entry.row.Text_SettingName.justification,0);
        assert.equal(entry.row.Text_SettingName.Slot.alignment,0);
    }
});
test("原生文本缺失才回退引擎；读不到时保留上次语言",()=>{
    const UE={KismetInternationalizationLibrary:{GetCurrentLanguage:()=>"en-GB"}};
    assert.equal(gameLanguage(UE,"zhHans"),"en");
    UE.KismetInternationalizationLibrary.GetCurrentLanguage=()=>"";
    assert.equal(gameLanguage(UE,"zhHans"),"zhHans");
    UE.KismetInternationalizationLibrary.GetCurrentLanguage=()=>{throw Error("loading");};
    assert.equal(gameLanguage(UE,"zhHant"),"zhHant");
});
