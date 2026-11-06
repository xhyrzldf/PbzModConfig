'use strict';
// Use the existing authored translations, preserving the same language keys.
const {catalogs} = require('../src/LocaleStrings');
const languages = ['zhHans','zhHant','en','ko','ru','es-ES','es-419','vi'];
const keys = ['tab','unavailable','failed','pending','off','on',
    'pressKey','unbound','clearBinding','editRejected',
    'cancel','applyColor','red','green','blue','alpha','preview','stop','bindingConflict',
    'reset','confirm','colorBefore','colorAfter','expand','collapse','version','empty'];
const words = {};
for (const key of keys) {
    words[key] = {};
    for (const language of languages) {
        const value = catalogs[language] && catalogs[language][key];
        if (typeof value !== 'string' || !value) throw new Error('FRAMEWORK_TRANSLATION_MISSING ' + language + ' ' + key);
        words[key][language] = value;
    }
}
const payload = JSON.stringify(words);
let equals = '';
while (payload.includes(']' + equals + ']')) equals += '=';
process.stdout.write('-- Generated from the existing framework translations.\n' +
    'local json = require("dkjson")\n' +
    'local value, _, err = json.decode([' + equals + '[' + payload + ']' + equals + '])\n' +
    'assert(value and not err, "FRAMEWORK_TRANSLATIONS_DECODE_FAILED " .. tostring(err))\n' +
    'return value\n');
