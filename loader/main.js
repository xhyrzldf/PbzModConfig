"use strict";

const settingModule = require("UI/Setting/SettingPanel");
module.exports = require("./LoaderAdapter").install(settingModule, require("ue"), require("puerts"));
console.log("[PbzModConfig] loader entry installed");
