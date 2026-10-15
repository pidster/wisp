// The docs' menu-bar title as a link home, with the wisp mark (ADR 0065). mdBook renders the title as plain
// text; without JavaScript it stays so. path_to_root is the book's root, set by mdBook on every page; the
// homepage is one level above it, at the site's root.
(function () {
    "use strict";
    var title = document.querySelector(".menu-title");
    if (!title || typeof path_to_root === "undefined") return;
    var link = document.createElement("a");
    link.className = "wisp-home";
    link.href = path_to_root + "../";
    link.setAttribute("aria-label", "wisp, home");
    // mdBook names its files with a hash of their content, so the mark is found by the page's own icon link.
    var icon = document.querySelector('link[rel="icon"][href$=".svg"]');
    var mark = document.createElement("img");
    mark.src = icon ? icon.href : "";
    mark.alt = "";
    mark.width = 22;
    mark.height = 22;
    var name = document.createElement("span");
    name.textContent = "wisp";
    link.appendChild(mark);
    link.appendChild(name);
    title.textContent = "";
    title.appendChild(link);
})();
