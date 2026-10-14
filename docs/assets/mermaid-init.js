// Draws the docs' ```mermaid blocks on the documentation site (ADR 0065). GitHub draws them itself; mdBook
// renders them as code, so this replaces each with mermaid's drawing. mermaid is loaded from jsDelivr at a
// pinned version, only on a page that has a diagram; if it cannot load, the diagram's source stays shown.
(function () {
    "use strict";
    var blocks = document.querySelectorAll("code.language-mermaid");
    if (blocks.length === 0) {
        return;
    }
    var root = document.documentElement.classList;
    var dark = root.contains("coal") || root.contains("navy") || root.contains("ayu");
    blocks.forEach(function (code) {
        var diagram = document.createElement("pre");
        diagram.className = "mermaid";
        diagram.textContent = code.textContent;
        code.parentElement.replaceWith(diagram);
    });
    import("https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs")
        .then(function (module) {
            var mermaid = module.default;
            mermaid.initialize({ startOnLoad: false, theme: dark ? "dark" : "default" });
            return mermaid.run({ querySelector: "pre.mermaid" });
        })
        .catch(function () {
            // The source stays shown as text.
        });
})();
