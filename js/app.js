/* =============================================================
   Action Plus Sports Images — Main Application JS
   Reads from static galleries.json (updated by server-side cron)
   ============================================================= */

(function () {
  'use strict';

  var PS_SITE = 'https://actionplusps.photoshelter.com';
  var MAX_GALLERIES = 60;

  // ---- Fix header padding on all pages ----
  function fixHeaderPadding() {
    var hdr = document.querySelector('.site-header');
    var wrap = document.getElementById('gridWrap') || document.querySelector('.page-content');
    if (hdr && wrap) {
      wrap.style.paddingTop = hdr.offsetHeight + 'px';
    }
  }

  // ---- Grid aspect ratio logic (from original v4) ----
  function calcAspect(cellW) {
    var WIDE = 450, NARROW = 270;
    var RATIO_32 = 2 / 3;
    var RATIO_SQ = 1;
    if (cellW >= WIDE)   return RATIO_32;
    if (cellW <= NARROW) return RATIO_SQ;
    var t = (cellW - NARROW) / (WIDE - NARROW);
    return RATIO_SQ + t * (RATIO_32 - RATIO_SQ);
  }

  // Pick count that fills grid rows evenly
  function pickCount(cols, total) {
    if (total <= 0) return 0;
    var rounded = Math.floor(total / cols) * cols;
    return rounded > 0 ? rounded : Math.min(total, cols);
  }

  // ---- Load galleries from static JSON ----
  function loadGalleries() {
    return fetch('galleries.json?t=' + Math.floor(Date.now() / 60000))
      .then(function (res) {
        if (!res.ok) throw new Error('galleries.json returned ' + res.status);
        return res.json();
      })
      .then(function (manifest) {
        return (manifest.galleries || []).map(function (g) {
          return {
            id:    g.id,
            name:  g.name,
            url:   g.url,
            image: g.image,
            num_images: g.num_images || 0
          };
        });
      });
  }

  // ---- Build the photo grid ----
  function buildGrid(galleries) {
    var grid = document.getElementById('photoGrid');
    if (!grid) return;

    var W     = window.innerWidth;
    var GAP   = 12;
    var cols  = Math.max(2, Math.floor(W / 360));
    var count = pickCount(cols, Math.min(galleries.length, MAX_GALLERIES));
    var cellW = (W - GAP * (cols - 1)) / cols;
    var cellH = Math.round(cellW * calcAspect(cellW));

    grid.style.gridTemplateColumns = 'repeat(' + cols + ', 1fr)';
    grid.style.gridAutoRows        = cellH + 'px';
    grid.innerHTML = '';

    for (var i = 0; i < count; i++) {
      var g    = galleries[i];
      var cell = document.createElement('a');
      cell.className = 'photo-cell';
      cell.href = g.url || '#';
      cell.target = '_blank';
      cell.rel = 'noopener';

      var imgSrc = g.image || '';
      var imgAlt = g.name || '';
      var info = parseGalleryInfo(g.name);
      var badgeHtml = g.num_images > 0
        ? '<div class="cell-badge"><svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2"><rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8.5" cy="8.5" r="1.5"/><path d="M21 15l-5-5L5 21"/></svg> ' + g.num_images + ' images</div>'
        : '';

      cell.innerHTML =
        (imgSrc
          ? '<img src="' + escHtml(imgSrc) + '" alt="' + escHtml(imgAlt) + '" loading="' + (i < 20 ? 'eager' : 'lazy') + '"/>'
          : '<div style="width:100%;height:100%;background:#1a1a1a"></div>'
        ) +
        badgeHtml +
        '<div class="cell-label">' +
          '<div class="cell-label-date">' + escHtml(info.date) + '</div>' +
          '<div class="cell-label-title">' + escHtml(info.title) + '</div>' +
        '</div>' +
        '<div class="hover-info">' +
          '<div class="hover-date">' + escHtml(info.date) + '</div>' +
          '<div class="hover-event">' + escHtml(info.title) + '</div>' +
        '</div>';

      grid.appendChild(cell);
    }

    fixHeaderPadding();
  }

  // ---- Parse date and title from gallery name ----
  // Names like "2026 Premier League Football Chelsea v Tottenham May 19th"
  var MONTHS = 'January|February|March|April|May|June|July|August|September|October|November|December|Jan|Feb|Mar|Apr|Jun|Jul|Aug|Sep|Oct|Nov|Dec';
  var DATE_RE = new RegExp('^(\\d{4})\\s+(.+?)\\s+(' + MONTHS + ')\\s+(\\d{1,2})(?:st|nd|rd|th)?\\s*$', 'i');

  function parseGalleryInfo(name) {
    var m = DATE_RE.exec(name);
    if (m) {
      return { date: m[3] + ' ' + m[4] + ', ' + m[1], title: m[2] };
    }
    // Fallback: try just year prefix
    var y = /^(\d{4})\s+(.+)/.exec(name);
    if (y) return { date: y[1], title: y[2] };
    return { date: '', title: name };
  }

  // ---- HTML escape helper ----
  function escHtml(str) {
    var div = document.createElement('div');
    div.appendChild(document.createTextNode(str));
    return div.innerHTML;
  }

  // ---- Show loading state ----
  function showLoading() {
    var grid = document.getElementById('photoGrid');
    if (grid) grid.innerHTML = '<div class="grid-loading">Loading galleries&hellip;</div>';
  }

  // ---- Show error state ----
  function showError(msg) {
    var grid = document.getElementById('photoGrid');
    if (grid) grid.innerHTML = '<div class="grid-error">' + escHtml(msg) + '</div>';
  }

  // ---- State ----
  var currentGalleries = [];

  // ---- Init ----
  function init() {
    showLoading();

    loadGalleries()
      .then(function (galleries) {
        currentGalleries = galleries;
        if (galleries.length === 0) {
          showError('No galleries found.');
          return;
        }
        buildGrid(galleries);
      })
      .catch(function (err) {
        console.error('Failed to load galleries:', err);
        showError('Could not load galleries. Please try again later.');
      });
  }

  // ---- Resize handler ----
  var resizeTimer;
  window.addEventListener('resize', function () {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(function () {
      if (currentGalleries.length > 0) {
        buildGrid(currentGalleries);
      }
    }, 60);
  });

  // ---- Hamburger menu ----
  var burger = document.getElementById('burger');
  if (burger) {
    burger.addEventListener('click', function () {
      document.getElementById('navLinks').classList.toggle('open');
    });
  }

  // ---- Search: redirect to PhotoShelter ----
  function doSearch() {
    var box = document.getElementById('searchBox');
    if (!box) return;
    var terms = box.value.trim();
    if (!terms) return;
    // Use a form-based submit to avoid popup blockers
    var a = document.createElement('a');
    a.href = PS_SITE + '/search?I_DSC=' + encodeURIComponent(terms) + '&I_DSC_AND=t&_ACT=search&I_SORT=DATE';
    a.target = '_blank';
    a.rel = 'noopener';
    document.body.appendChild(a);
    a.click();
    document.body.removeChild(a);
  }

  var searchBtn = document.getElementById('searchBtn');
  if (searchBtn) {
    searchBtn.addEventListener('click', doSearch);
  }

  var searchBox = document.getElementById('searchBox');
  if (searchBox) {
    searchBox.addEventListener('keydown', function (e) {
      if (e.key === 'Enter') doSearch();
    });
  }

  // ---- Kick off ----
  if (document.getElementById('photoGrid')) {
    init();
  }

  fixHeaderPadding();
  window.addEventListener('load', fixHeaderPadding);

})();
