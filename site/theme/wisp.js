// The docs' bar as the site's own (ADR 0065), with wisp.css: the menu bar's title becomes the mark and name, linked
// home, with "Docs" beside it; the search button reads as a search field; and the homepage's links join the icons
// on the right. mdBook renders none of this; without JavaScript the bar is mdBook's own, still working.
// path_to_root is the book's root, set by mdBook on every page; the homepage is one level above it.
(function () {
    "use strict";
    if (typeof path_to_root === "undefined") return;
    var make = function (tag, attributes, text) {
        var element = document.createElement(tag);
        Object.keys(attributes).forEach(function (name) { element.setAttribute(name, attributes[name]); });
        if (text) element.textContent = text;
        return element;
    };

    var title = document.querySelector(".menu-title");
    if (title) {
        var home = make("a", { "class": "wisp-home", href: path_to_root + "../", "aria-label": "wisp, home" });
        // mdBook names its files with a hash of their content, so the mark is found by the page's own icon link.
        var icon = document.querySelector('link[rel="icon"][href$=".svg"]');
        if (icon) home.appendChild(make("img", { src: icon.href, alt: "", width: "24", height: "24" }));
        home.appendChild(make("span", {}, "wisp"));
        var docs = make("a", { "class": "wisp-section", href: path_to_root + "index.html" }, "Docs");
        title.textContent = "";
        title.appendChild(home);
        title.appendChild(docs);
    }

    var search = document.getElementById("mdbook-search-toggle");
    if (search) {
        search.classList.add("wisp-search");
        search.appendChild(make("span", { "class": "wisp-search-label" }, "Search the docs"));
        search.appendChild(make("kbd", {}, "/"));
    }

    var right = document.querySelector("#mdbook-menu-bar .right-buttons");
    if (right) {
        var nav = make("nav", { "class": "wisp-nav", "aria-label": "Site" });
        [["Guides", "guide/install.html"], ["Reference", "wisp.html"], ["Changelog", "changelog.html"]].forEach(function (link) {
            nav.appendChild(make("a", { href: path_to_root + link[1] }, link[0]));
        });
        right.insertBefore(nav, right.firstChild);
    }
})();
