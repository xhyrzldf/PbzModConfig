"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const repository = path.resolve(__dirname, "..");
const localRoot = path.join(repository, ".local/pbz-modconfig");
fs.mkdirSync(localRoot, { recursive: true });
const testRoot = fs.mkdtempSync(path.join(localRoot, "loader-tests-"));
const output = path.join(testRoot, "build");
const result = spawnSync(process.env.PYTHON || "python", [
    path.join(__dirname, "../build.py"), "--runtime", "pbzmodloader", "--out", output
], { encoding: "utf8" });
const mod = path.join(output, "stage/ProjectPBZ/PBZModLoader/mods/pbz-mod-config");

test.after(() => {
    const relative = path.relative(fs.realpathSync(localRoot), fs.realpathSync(testRoot));
    assert.ok(relative.startsWith("loader-tests-") && !relative.includes(path.sep));
    fs.rmSync(testRoot, { recursive: true });
});

test("prepared locale catalogs are standalone and resolve their real translation dependency", () => {
    assert.equal(result.status, 0, result.stderr);
    const filename = path.join(mod, "src/LocaleStrings.js");
    assert.ok(!fs.readFileSync(filename, "utf8").includes("PbzMapTracker"));
    const { catalogs, words } = require(filename);
    for (const locale of ["zhHans", "zhHant", "en", "ko", "ru", "es-ES", "es-419", "vi"]) {
        assert.ok(catalogs[locale].tab.length > 0, locale);
        assert.equal(words.tab[locale], catalogs[locale].tab);
        assert.ok(words.pressKey[locale].length > 0, locale);
    }
});

test("the actual authored Entry dependency graph loads without any game or map module", () => {
    assert.equal(result.status, 0, result.stderr);
    const entry = require(path.join(mod, "native/Entry.js"));
    assert.equal(typeof entry.install, "function");
    const loaded = Object.keys(require.cache).filter(filename => filename.startsWith(mod + path.sep));
    assert.ok(loaded.some(filename => filename.endsWith(path.join("src", "LocaleStrings.js"))));
    assert.ok(loaded.every(filename => !filename.includes("PbzMapTracker")));
});
