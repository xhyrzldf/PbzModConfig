"use strict";
const { test } = require("node:test"), assert = require("node:assert/strict");
const { createRows } = require("../native/NativeRows");

function fixture(locale = "zhHans") {
    const reports = [], loaded = [], styles = new Map();
    const rowFont = { FontObject: "CN-font", TypefaceFontName: "Native", Size: 22,
        LetterSpacing: 80, FontMaterial: "native-material", OutlineSettings: { OutlineSize: 1 } };
    const label = () => {
        let font = structuredClone(rowFont);
        return { get Font() { return structuredClone(font); }, SetFont(value) { font = structuredClone(value); },
            SetVisibility() {}, SetJustification() {} };
    };
    const base = type => ({ GetClass: () => type, SetVisibility() {}, SetIsInteractionEnabled() {},
        SetIsFocusable() {}, SetIsEnabled() {}, RemoveFromParent() {}, SetSelected() {} });
    const rotator = () => Object.assign(base("Rotator"), { Text: label(), index: -1,
        PopulateTextLabels(values) { this.values = values.values; },
        SetSelectedItem(index) {
            this.index = index;
            // Reproduce the native decorator using Chinese for each selection.
            this.Text.SetFont(rowFont);
            this.selectedText = this.values[index];
        }, GetSelectedIndex() { return this.index; } });
    const row = Object.assign(base("Row"), { Rotator_SettingValue: rotator(),
        Button_Decrease: base("Button"), Button_Increase: base("Button"), Text_SettingName: label() });
    const UE = {
        Class: { Load(path) { loaded.push(path); return path; } }, BuiltinText: {},
        NewArray: () => ({ values: [], Add(value) { this.values.push(value); } }),
        EWidgetTickFrequency: { Never: 0 }, EHorizontalAlignment: {}, EVerticalAlignment: {}, ETextJustify: {},
        SGameAIFunctionLibrary: { GetClassDefaultObject(path) {
            const suffix = path.match(/Textstyle_Main_(\w+)\./)[1];
            if (!styles.has(suffix)) styles.set(suffix, { Font: { FontObject: suffix + "-font",
                TypefaceFontName: "Regular", LetterSpacing: 0, Size: 17 } });
            return styles.get(suffix);
        } }
    };
    let RowHost;
    const puerts = { blueprint: { tojs: value => value, mixin(type, implementation, config) {
        RowHost = implementation; config.generatedClass = implementation;
    } } };
    const ui = { V: { SelfHitTestInvisible: 1 }, valid: value => !!value, asText: value => value,
        text() {}, replaceControl() {}, lifetime: () => ({ live: true, bind() {}, dispose() {} }),
        widget(owner, type) { return type === "Rotator" ? rotator() : type === "Button" ? base(type) : row; } };
    const options = [{ value: "ko", label: "한국어" }, { value: "ru", label: "Русский" },
        { value: "zh-Hant", label: "繁體中文" }, { value: "en", label: "English" },
        { value: "es", label: "Español (Latinoamérica)" }, { value: "zh", label: "中文" },
        { value: "auto", label: "跟随游戏 / Auto" }];
    const model = { id: "map/language", type: "choice", label: "显示语言 / Language", value: "ko", options };
    const item = {}, state = { locale, entries: new Map(), models: new Map([[item, model]]), panel: {},
        acceptsInput: () => true, rowReady() {}, word: () => "不可用" };
    createRows(UE, puerts, ui, new Map([[item, state]]), event => reports.push(event));
    const host = new RowHost(); host.WidgetTree = { RootWidget: { GetChildrenCount: () => 0, AddChild: () => ({}) } };
    host.OnListItemObjectSet(item);
    assert.deepEqual(reports, []);
    const binding = state.entries.get(model.id); assert.ok(binding);
    return { binding, model, row, rowFont, styles, loaded, reports };
}

test("Chinese menu renders each language's own name, including Korean, after native selection styling", () => {
    const f = fixture();
    for (const [value, family] of [["ko", "KR"], ["ru", "RU"], ["zh-Hant", "TC"],
        ["en", "EN"], ["es", "EN"], ["zh", "CN"], ["auto", "CN"], ["ko", "KR"]]) {
        f.model.value = value; f.binding.refresh(f.model);
        const control = f.row.Rotator_SettingValue, font = control.Text.Font;
        assert.equal(control.selectedText, f.model.options.find(option => option.value === value).label);
        assert.equal(font.FontObject, family + "-font", value + " uses a font containing its script");
        assert.equal(font.Size, f.rowFont.Size, "changing the glyph face must not alter row size");
        assert.equal(font.FontMaterial, f.rowFont.FontMaterial);
        assert.deepEqual(font.OutlineSettings, f.rowFont.OutlineSettings);
        assert.equal(font.LetterSpacing, 0);
    }
    assert.deepEqual(f.row.Text_SettingName.Font, f.rowFont, "value styling must not change the setting name");
    for (const style of f.styles.values()) assert.equal(style.Font.Size, 17, "shared native style remains unchanged");
    assert.equal(f.loaded.filter(path => /Textstyle_Main_KR\./.test(path)).length, 1, "native font lookup is cached");
});

test("The same choice remains legible in all seven menu languages", () => {
    for (const locale of ["zhHans", "en", "zhHant", "ko", "ru", "es-ES", "es-419"]) {
        const f = fixture(locale);
        assert.equal(f.row.Rotator_SettingValue.Text.Font.FontObject, "KR-font");
    }
});
