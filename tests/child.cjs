"use strict";
const { createDemo } = require("../demo/DemoProvider");
const { fileIO } = require("./fixtures.cjs");
const [directory, mode] = process.argv.slice(2);
const demo = createDemo(fileIO(directory, "PbzConfigDemo"));
if (mode === "write") {
    demo.store.apply({ enabled: false, opacity: 0.45, placement: "left" });
    if (!demo.store.flush().ok) process.exitCode = 1;
}
process.stdout.write(JSON.stringify(demo.store.read()));
demo.dispose();
