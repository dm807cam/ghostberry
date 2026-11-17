/* Almanac — menu toggle and table of contents. No dependencies. */
(function () {
    'use strict';

    // Phone menu: the rail's navigation and subscribe form fold away.
    var rail = document.querySelector('[data-rail]');
    var toggle = document.querySelector('[data-menu-toggle]');
    if (rail && toggle) {
        toggle.addEventListener('click', function () {
            var open = rail.classList.toggle('is-open');
            toggle.setAttribute('aria-expanded', open ? 'true' : 'false');
        });
    }

    // Table of contents, built from the post's h2 and h3 headings.
    var content = document.querySelector('[data-content]');
    var tocs = document.querySelectorAll('[data-toc]');
    if (!content || !tocs.length) { return; }

    var headings = Array.prototype.filter.call(
        content.querySelectorAll('h2, h3'),
        function (h) { return h.textContent.trim() && !h.closest('.kg-card'); }
    );
    if (headings.length < 2) { return; }

    var used = {};
    headings.forEach(function (h, i) {
        if (!h.id) { h.id = 'section-' + (i + 1); }
        if (used[h.id]) { h.id = h.id + '-' + (i + 1); }
        used[h.id] = true;
    });

    var links = [];
    Array.prototype.forEach.call(tocs, function (toc) {
        var list = toc.querySelector('[data-toc-list]');
        headings.forEach(function (h) {
            var li = document.createElement('li');
            var a = document.createElement('a');
            a.href = '#' + h.id;
            a.textContent = h.textContent.trim();
            a.dataset.target = h.id;
            if (h.tagName === 'H3') { li.className = 'toc-sub'; }
            li.appendChild(a);
            list.appendChild(li);
            links.push(a);
        });
        toc.hidden = false;
    });

    function mark(id) {
        links.forEach(function (a) {
            if (a.dataset.target === id) {
                a.setAttribute('aria-current', 'true');
            } else {
                a.removeAttribute('aria-current');
            }
        });
    }

    // The current section is the last heading above the upper third of the window.
    var ticking = false;
    function update() {
        ticking = false;
        var line = window.innerHeight * 0.33;
        var current = null;
        for (var i = 0; i < headings.length; i++) {
            if (headings[i].getBoundingClientRect().top <= line) {
                current = headings[i].id;
            } else {
                break;
            }
        }
        mark(current);
    }
    window.addEventListener('scroll', function () {
        if (!ticking) { ticking = true; window.requestAnimationFrame(update); }
    }, { passive: true });
    update();
})();
