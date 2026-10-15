// The docs' bar as the site's own (ADR 0065), with wisp.css: the menu bar's title becomes the mark and name, linked
// home, with "docs" beside it; the search button reads as a search field; and the homepage's links join the icons
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
        var docs = make("a", { "class": "wisp-section", href: path_to_root + "index.html" }, "docs");
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

    // Light or dark, dark by default (book.toml). The toggle presses mdBook's own hidden theme buttons, so mdBook
    // stores the choice ("mdbook-theme", which the homepage reads too) and switches its highlighting with it.
    // light and rust are wisp's light; every other theme is its dark.
    var html = document.documentElement;
    var isLight = function () { return html.classList.contains("light") || html.classList.contains("rust"); };
    var svg = function (path) {
        return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" fill="none" stroke="currentColor" ' +
            'stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + path + "</svg>";
    };
    var sun = svg('<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4' +
        'M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4"/>');
    var moon = svg('<path d="M21 12.8A9 9 0 1 1 11.2 3a7 7 0 0 0 9.8 9.8z"/>');
    // The overview picture chooses by the system's setting; it follows the page's theme instead.
    var darkSources = document.querySelectorAll('picture source[media*="prefers-color-scheme: dark"]');
    var pictures = function () {
        darkSources.forEach(function (source) { source.media = isLight() ? "not all" : "all"; });
    };
    if (right && document.getElementById("mdbook-theme-light") && document.getElementById("mdbook-theme-navy")) {
        var toggle = make("button", { "class": "icon-button wisp-theme", type: "button" });
        var show = function () {
            var light = isLight();
            toggle.innerHTML = light ? moon : sun;
            toggle.title = light ? "Dark theme" : "Light theme";
            toggle.setAttribute("aria-label", toggle.title);
            pictures();
        };
        toggle.addEventListener("click", function () {
            document.getElementById(isLight() ? "mdbook-theme-navy" : "mdbook-theme-light").click();
        });
        new MutationObserver(show).observe(html, { attributes: true, attributeFilter: ["class"] });
        show();
        right.appendChild(toggle);
    } else {
        pictures();
    }
})();
