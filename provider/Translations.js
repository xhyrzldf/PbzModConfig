"use strict";
// Copy with the provider template. No framework import or runtime dependency.
// Input: { en: { title: "..." }, zhHans: { title: "..." }, ... }
// Output: { title: { en: "...", zhHans: "..." }, ... }, accepted by protocol v1.
function createTranslations(catalogs) {
    const result = Object.create(null);
    for (const [locale, catalog] of Object.entries(catalogs)) {
        if (!catalog || typeof catalog !== "object" || Array.isArray(catalog)) throw new TypeError("Invalid translation catalog: " + locale);
        for (const [key, text] of Object.entries(catalog)) {
            if (typeof text !== "string") throw new TypeError("Translation must be a string: " + locale + "/" + key);
            if (!result[key]) result[key] = Object.create(null);
            result[key][locale] = text;
        }
    }
    for (const value of Object.values(result)) Object.freeze(value);
    return Object.freeze(result);
}
module.exports = { createTranslations };
