# APSI WordPress Plugin Specification

Technical documentation for converting the Action Plus Sports Images (APSI) static site into a WordPress plugin.

---

## Overview

This site displays a responsive grid of sports photography gallery cover images scraped from PhotoShelter. It runs as a standalone HTML/CSS/JS site with a PHP cron script for syncing gallery data. The goal is to convert it into a WordPress plugin that integrates with the existing actionplus.co.uk WordPress site.

**Key design decisions:**
- No PhotoShelter API key required — scrapes the public gallery-list page
- Images stored locally as WebP for fast loading and GDPR compliance
- Fonts self-hosted (no Google Fonts CDN) for GDPR compliance
- Cache-busting on PhotoShelter CDN requests to detect cover image changes immediately
- ETag-based change detection to avoid unnecessary image downloads
- Browser cache headers ensure visitors always see fresh content without manual refresh

---

## Architecture

### Current Flow

1. A cron script (`api/sync.php`) runs every 10 minutes
2. It scrapes the public page at `https://actionplusps.photoshelter.com/gallery-list`
3. Compares scraped gallery IDs against the existing `galleries.json` manifest
4. Uses HTTP HEAD requests with cache-busting (`?t=timestamp`) to detect updated cover images via ETag comparison
5. Downloads cover images only for **new or updated** galleries
6. Converts images from JPEG to WebP (quality 84) and stores them locally in `images/`
7. Cleans up images and ETags for galleries that have rotated off the page
8. Writes `galleries.json` — a manifest of all galleries with local image paths
9. The frontend reads `galleries.json` (with a per-minute cache-buster) and builds a responsive CSS Grid

### What the Plugin Needs to Do

- Register a shortcode (e.g., `[apsi_gallery_grid]`) that renders the grid on any page
- Enqueue the CSS and JS assets (including self-hosted fonts)
- Provide a WP-Cron scheduled task (every 10 minutes) that syncs galleries from PhotoShelter
- Store images in `wp-content/uploads/apsi/`
- Store the manifest as a WordPress transient or option, or as a JSON file in the uploads directory
- Store an ETag cache for cover image change detection
- Provide an admin settings page for configuration (PhotoShelter URL, sync interval, grid settings)
- Set appropriate cache-control headers for the manifest and images

---

## PhotoShelter Integration

### Source URL

```
https://actionplusps.photoshelter.com/gallery-list
```

No API key is required. This is a public page.

### Scraping Regex

The gallery-list page contains `<li>` elements with this structure:

```html
<li>
  <table>
    <tr>
      <td class="slide">
        <a href="https://actionplusps.photoshelter.com/gallery/{slug}/{gallery_id}/">
          <img src="https://m.psecn.photoshelter.com/img-get/{image_id}/t/200/{image_id}.jpg"
               alt="Gallery Name">
        </a>
      </td>
    </tr>
  </table>
</li>
```

**Regex pattern to extract galleries:**

```regex
/<a\s+href="([^"]*\/gallery\/[^"]+\/(G[A-Za-z0-9._]+)\/?)"[^>]*>\s*<img\s+src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>/i
```

**IMPORTANT:** Gallery IDs can contain underscores (e.g., `G0000SN_ESMfLDog`). The character class must include `_` — using `[A-Za-z0-9._]` not `[A-Za-z0-9.]`.

**Capture groups:**

| Group | Content | Example |
|-------|---------|---------|
| 1 | Full gallery URL | `https://actionplusps.photoshelter.com/gallery/2026-Serie-A.../G0000wm0ffiiMh7U/` |
| 2 | Gallery ID | `G0000wm0ffiiMh7U` |
| 3 | Thumbnail image URL | `https://m.psecn.photoshelter.com/img-get/I0000.../t/200/I0000....jpg` |
| 4 | Gallery name | `2026 Serie A Football Roma v Pisa Apr 10th` |

Deduplicate by gallery ID (the page contains duplicate links per gallery).

### Image URL Transformation

The scraped thumbnail URL uses `/t/200/` (200px thumbnail). To get a higher quality image:

- Replace `/t/\d+/` with `/s/1200/` in the URL
- `/t/` = thumbnail quality (compressed), `/s/` = standard quality (less compressed)
- Maximum dimension returned is 1000px regardless of size requested
- The resulting JPEG is ~342KB per image
- **Always append a cache-buster** (`?t=` + unix timestamp) to bypass PhotoShelter's 24-hour CDN cache

### Image Processing

1. Download JPEG from transformed CDN URL (with cache-buster query param)
2. Convert to WebP using GD library: `imagecreatefromstring()` + `imagewebp($img, $path, 84)`
3. Store as `{gallery_id}.webp` (e.g., `G0000wm0ffiiMh7U.webp`)
4. Average output size: ~105KB per image in WebP (~10MB total for ~100 galleries)

### CDN Cache-Busting

PhotoShelter's CDN (`m.psecn.photoshelter.com`) returns `Cache-Control: max-age=86400` (24-hour cache). When a cover image is updated on PhotoShelter, the CDN may continue serving the old version for up to 24 hours.

To bypass this:
- Append `?t=` + current unix timestamp to all image download and HEAD request URLs
- This forces the CDN to fetch from origin, returning the latest image
- Without cache-busting, ETag comparisons would match the stale cached version

### Sync Logic (Incremental with Change Detection)

```
1.  Load existing gallery manifest (galleries.json)
2.  Load ETag cache (etags.json)
3.  Fetch https://actionplusps.photoshelter.com/gallery-list
4.  Parse HTML with regex to extract galleries
5.  Deduplicate by gallery ID, preserve page order (newest first)
6.  Detect NEW galleries: IDs not in existing manifest
7.  Detect UPDATED covers: for each existing gallery with a cached ETag,
    send a cache-busted HEAD request to the image CDN URL and compare
    the returned ETag against the cached ETag. If different, the cover
    image has changed on PhotoShelter.
8.  If no new or updated galleries → exit (no work to do)
9.  For each NEW or UPDATED gallery:
    a. Transform image URL: /t/\d+/ → /s/1200/
    b. Append cache-buster: ?t={unix_timestamp}
    c. Download JPEG
    d. Convert to WebP (quality 84)
    e. Save to images directory
    f. Store the ETag from a cache-busted HEAD request for future
       change detection
10. Save ETag cache (etags.json)
11. Rebuild manifest in scraped order (newest first, only galleries
    currently on the page)
12. Write manifest file (galleries.json)
13. Clean up old images: delete any .webp files for gallery IDs
    no longer present on the gallery-list page
14. Clean up stale ETags for removed galleries
```

**Change detection:** The sync uses HTTP `ETag` headers with cache-busted URLs to detect when a gallery's cover image has been updated on PhotoShelter. A HEAD request returns only headers (~200 bytes) compared to a full image download (~350KB). ETags are cached in `etags.json`. Cache-busting ensures we check the origin server, not the CDN cache.

**Cleanup logic:** As new galleries are published on PhotoShelter, older galleries rotate off the gallery-list page. The sync script detects images in the `images/` directory whose gallery ID is no longer in the scraped results and deletes them, along with their cached ETags. This keeps the image cache bounded to roughly the same number of galleries PhotoShelter displays (~100).

---

## Gallery Manifest Format (galleries.json)

```json
{
  "updated": "2026-04-11T12:30:00+00:00",
  "count": 100,
  "galleries": [
    {
      "id": "G0000wm0ffiiMh7U",
      "name": "2026 Serie A Football Roma v Pisa Apr 10th",
      "url": "https://actionplusps.photoshelter.com/gallery/2026-Serie-A-Football-Roma-v-Pisa-Apr-10th/G0000wm0ffiiMh7U/",
      "image": "images/G0000wm0ffiiMh7U.webp"
    }
  ]
}
```

In WordPress, `image` paths should be relative to the uploads directory or use `wp_get_upload_dir()`.

---

## Browser Caching Strategy

To ensure visitors always see fresh content without manual hard-refresh:

### JavaScript Cache-Busting

The frontend appends a per-minute timestamp to the `galleries.json` request:

```javascript
fetch('galleries.json?t=' + Math.floor(Date.now() / 60000))
```

This ensures the manifest is re-fetched at most once per minute.

### Apache .htaccess Headers

```apache
# galleries.json — never cache (always check for updates)
<FilesMatch "galleries\.json">
  Header set Cache-Control "no-cache, must-revalidate"
</FilesMatch>

# WebP images — cache for 10 minutes, then revalidate
<FilesMatch "\.webp$">
  Header set Cache-Control "public, max-age=600, must-revalidate"
</FilesMatch>

# CSS/JS — cache for 1 hour
<FilesMatch "\.(css|js)$">
  Header set Cache-Control "public, max-age=3600"
</FilesMatch>

# HTML — no cache
<FilesMatch "\.html$">
  Header set Cache-Control "no-cache, must-revalidate"
</FilesMatch>
```

**How `must-revalidate` works:** The browser sends a conditional request to the server. If the file hasn't changed, the server returns `304 Not Modified` (no data transferred). Only if the file actually changed does it download the new version. This means ~200 bytes per image check, not a full re-download.

In WordPress, these headers should be set via `send_headers` action or in the theme/plugin.

---

## Frontend: HTML Structure

### Header

```html
<header class="site-header">
  <div class="nav-black">
    <a class="nav-logo" href="index.html">
      <img src="images/logo.png" alt="Action Plus Sports Images"/>
      <span class="nav-tagline">Uncompromising sports photography for the world's media</span>
    </a>

    <div class="nav-right" id="navLinks">
      <nav class="nav-links">
        <a href="index.html" class="active">Home</a>
        <a href="https://actionplusps.photoshelter.com/gallery-list">Recent Events</a>
        <a href="https://www.actionplus.co.uk/about-us/">About</a>
        <a href="https://www.actionplus.co.uk/photographers/">Prospective Photographers</a>
      </nav>
      <div class="nav-login-wrap">
        <a class="nav-login-btn" href="https://actionplusps.photoshelter.com/login?ref=%2Fusr%2Finvites" target="_blank" rel="noopener">Login</a>
        <a class="nav-register" href="https://actionplusps.photoshelter.com/signup/signup" target="_blank" rel="noopener">Register</a>
      </div>
    </div>

    <div class="nav-hamburger" id="burger">
      <span></span><span></span><span></span>
    </div>
  </div>

  <div class="search-strip">
    <div class="search-inner">
      <input class="search-input" type="text" id="searchBox"
             placeholder="Search athletes, events, sports, image number..."/>
      <button class="search-btn" id="searchBtn">
        <svg viewBox="0 0 24 24">
          <circle cx="11" cy="11" r="7"/>
          <line x1="16.5" y1="16.5" x2="21" y2="21"/>
        </svg>
        Search
      </button>
    </div>
    <div class="search-advanced">
      <a href="https://actionplusps.photoshelter.com/search-page"
         target="_blank" rel="noopener">Advanced Search</a>
    </div>
  </div>
</header>
```

### Grid (populated by JavaScript)

```html
<div class="grid-wrap" id="gridWrap">
  <div class="photo-grid" id="photoGrid"></div>
</div>
```

Each grid cell is generated as:

```html
<a class="photo-cell" href="{gallery_url}" target="_blank" rel="noopener">
  <img src="{local_image_path}" alt="{gallery_name}" loading="eager|lazy"/>
  <div class="hover-info">
    <div class="hover-event">{gallery_name}</div>
  </div>
</a>
```

- First 20 images: `loading="eager"`
- Remaining images: `loading="lazy"`
- Gallery count is trimmed to fill the last row completely (no partial rows)

### Footer

```html
<footer class="site-footer">
  <div class="footer-logo">Action Plus Sports Images</div>
  <div class="footer-links">
    <a href="https://www.actionplus.co.uk/contact-us/">Contact</a>
    <a href="https://www.actionplus.co.uk/site-licence/">Terms</a>
    <a href="https://www.actionplus.co.uk/privacy/">Privacy</a>
  </div>
  <div class="footer-copy">&copy; 2026 Portray Limited</div>
</footer>
```

---

## Frontend: JavaScript (js/app.js)

### Gallery Loading

```javascript
// Fetches galleries.json with per-minute cache-buster
fetch('galleries.json?t=' + Math.floor(Date.now() / 60000))
```

### Gallery Cap

```javascript
var MAX_GALLERIES = 100;
// Grid displays at most MAX_GALLERIES, trimmed to fill the last row.
// This is independent of how many galleries the sync script pulls in.
var count = pickCount(cols, Math.min(galleries.length, MAX_GALLERIES));
```

### Grid Layout Algorithm

```javascript
// Responsive column count
var cols = Math.max(2, Math.floor(windowWidth / 240));

// Aspect ratio interpolation based on cell width
// >= 300px wide → 3:2 ratio (landscape)
// <= 180px wide → 1:1 ratio (square)
// Between → linear interpolation
function calcAspect(cellW) {
  var WIDE = 300, NARROW = 180;
  var RATIO_32 = 2/3, RATIO_SQ = 1;
  if (cellW >= WIDE) return RATIO_32;
  if (cellW <= NARROW) return RATIO_SQ;
  var t = (cellW - NARROW) / (WIDE - NARROW);
  return RATIO_SQ + t * (RATIO_32 - RATIO_SQ);
}

// Trim gallery count to fill last row completely (no partial rows)
function pickCount(cols, total) {
  var rounded = Math.floor(total / cols) * cols;
  return rounded > 0 ? rounded : Math.min(total, cols);
}
```

### Grid CSS Properties Set by JS

```javascript
grid.style.gridTemplateColumns = 'repeat(' + cols + ', 1fr)';
grid.style.gridAutoRows = cellH + 'px';
// cellH = Math.round(cellW * calcAspect(cellW))
```

### Search Redirect

```javascript
var PS_SITE = 'https://actionplusps.photoshelter.com';
// On search submit — opens PhotoShelter search in new tab:
var url = PS_SITE + '/search?I_DSC=' + encodeURIComponent(terms)
        + '&I_DSC_AND=t&_ACT=search&I_SORT=DATE';
// Uses dynamically created <a> element to avoid popup blockers
```

### Resize Handling

- Debounced at 60ms
- Rebuilds entire grid on window resize

### Header Padding

- JS calculates `.site-header` height and sets `#gridWrap` padding-top dynamically

---

## Frontend: CSS (css/style.css)

### Fonts

```css
/* Self-hosted fonts (GDPR compliant — no external requests) */
font-family: 'Bebas Neue', sans-serif;   /* Footer logo */
font-family: 'DM Sans', sans-serif;      /* Everything else */
/* Weights: 300 (light), 400 (regular), 500 (medium) */
```

Fonts are self-hosted in `css/fonts/` as woff2 files with `@font-face` declarations in `style.css`. No Google Fonts CDN dependency — this is required for GDPR compliance as loading from Google's CDN transmits visitor IP addresses to Google.

Font files:
- `css/fonts/BebasNeue-Regular.woff2` (13KB)
- `css/fonts/DMSans-Variable.woff2` (47KB) — variable font covering weights 300/400/500

### Color Palette

| Usage | Color | Hex |
|-------|-------|-----|
| Page background | Near black | `#0a0a0a` |
| Header/footer background | Pure black | `#000` |
| Grid cell background | Dark gray | `#111` |
| Body text | Off-white | `#f0ede8` |
| Nav text | Medium gray | `#aaa` |
| Tagline text | Gray | `#888` |
| Accent (buttons, active links) | Cool silver | `#b0c4cc` |
| Accent hover | Lighter silver | `#c4d8e0` |
| Borders | Very dark gray | `#1a1a1a` |
| Footer text | Dark gray | `#444` |
| Copyright text | Darker gray | `#333` |
| Search strip background | Semi-transparent | `rgba(30,30,30,0.82)` |

### Key Dimensions

| Element | Property | Value |
|---------|----------|-------|
| Logo image | height | 84px |
| Tagline | font-size | 17px |
| Nav links | font-size | 11px |
| Search input | height | 48px |
| Search button | height | 48px |
| Search strip padding | top/sides/bottom | 28px 28px 16px |
| Grid gap | gap | 3px |
| Grid min columns | - | 2 |
| Column width target | - | 240px |

### Header Layout

- Logo and tagline left-aligned (`.nav-logo` with `align-items: flex-start`)
- Nav items and login/register aligned to bottom of header bar (`.nav-black` with `align-items: flex-end`)

### Responsive Breakpoint: max-width 700px

- `.nav-right` (containing nav links + login/register) hidden by default
- Hamburger menu (`.nav-hamburger`) becomes visible
- Hamburger toggles `.open` class on `.nav-right` (ID `navLinks`)
- When open, `.nav-right` drops down as absolute-positioned overlay below the header bar (`top: 100%`)
- Nav links stack vertically, login/register shown in a horizontal row
- Search strip padding reduced
- Footer stacks vertically

**Important:** The JS hamburger toggle targets `#navLinks` which is the `.nav-right` div, not `.nav-links`. The CSS must hide/show `.nav-right`, not `.nav-links`.

### Hover Effects

- Grid cells: image scales to 1.06x, brightness increases from 0.88 to 1.05
- Gradient overlay appears from bottom with gallery name
- Transitions: transform 0.5s, filter 0.3s, opacity 0.25s

---

## Configuration Values

These should be exposed in a WordPress admin settings page:

| Setting | Default Value | Description |
|---------|---------------|-------------|
| PhotoShelter URL | `https://actionplusps.photoshelter.com` | Base URL for the PhotoShelter account |
| Gallery List Path | `/gallery-list` | Path appended to base URL for scraping |
| Sync Interval | 10 minutes | How often WP-Cron checks for new galleries |
| Image Quality | 84 | WebP compression quality (1-100), ~10MB total for ~100 images |
| Image Size Mode | `/s/1200/` | CDN URL pattern for image quality/size |
| Search URL Params | `I_DSC_AND=t&_ACT=search&I_SORT=DATE` | Additional search query parameters |
| Login URL | `/login?ref=%2Fusr%2Finvites` | Path for client login |
| Register URL | `/signup/signup` | Path for registration |
| Advanced Search URL | `/search-page` | Path for advanced search page |
| Alert Email | `bob@actionplus.co.uk` | Email for sync failure alerts |
| Max Galleries | 100 | Maximum number of galleries to display in the grid |
| Lazy Load Threshold | 20 | Number of images to load eagerly |
| Copyright Text | `Portray Limited` | Copyright holder name |
| Gallery ID Regex | `G[A-Za-z0-9._]+` | Character class for gallery IDs (must include underscore) |

---

## WordPress Plugin Recommendations

### File Structure

```
apsi-gallery/
├── apsi-gallery.php           # Main plugin file
├── includes/
│   ├── class-apsi-sync.php    # Scraper/sync logic (port of sync.php)
│   ├── class-apsi-grid.php    # Shortcode rendering
│   └── class-apsi-admin.php   # Admin settings page
├── assets/
│   ├── css/
│   │   ├── apsi-grid.css      # Grid styles (port of style.css)
│   │   └── fonts/
│   │       ├── BebasNeue-Regular.woff2
│   │       └── DMSans-Variable.woff2
│   ├── js/
│   │   └── apsi-grid.js       # Grid builder (port of app.js)
│   └── images/
│       └── logo.png           # Site logo
└── readme.txt
```

### Key WordPress APIs to Use

- **WP-Cron:** `wp_schedule_event()` for the 10-minute sync
- **Transients:** `set_transient()` / `get_transient()` for caching the manifest and ETags
- **Options API:** `get_option()` / `update_option()` for admin settings
- **Upload Directory:** `wp_get_upload_dir()` for storing images in `wp-content/uploads/apsi/`
- **HTTP API:** `wp_remote_get()` / `wp_remote_head()` instead of cURL for fetching pages and ETags
- **Shortcodes:** `add_shortcode('apsi_gallery_grid', ...)` for embedding the grid
- **Admin Pages:** `add_options_page()` for the settings screen
- **Enqueue:** `wp_enqueue_style()` / `wp_enqueue_script()` with `wp_localize_script()` to pass the manifest URL to JS
- **Headers:** `send_headers` action for cache-control headers on manifest and image files

### Shortcode Usage

```
[apsi_gallery_grid]
```

Should render the full grid with header, search strip, gallery grid, and footer. Alternatively, provide separate shortcodes:

```
[apsi_search_bar]
[apsi_gallery_grid]
```

This allows the theme to handle header/footer while the plugin provides the functional components.

---

## SEO

- `robots.txt` blocks `/api/` from search engine crawlers
- `sitemap.xml` lists the homepage with `changefreq: hourly` (gallery grid updates frequently)
- When running as a WordPress plugin, both should be managed by WordPress or a plugin like Yoast instead of these static files
- Consider adding `<meta name="description">` and Open Graph tags to `index.html` before going live

---

## Monitoring / Alerts

The sync script sends an email alert to `bob@actionplus.co.uk` (configured in `api/config.php` as `ALERT_EMAIL`) when:

- The gallery-list page cannot be fetched (PhotoShelter down or URL changed)
- The scraping regex matches zero galleries (HTML structure changed)

Uses PHP `mail()` function. In WordPress, use `wp_mail()` instead.

---

## GDPR Compliance

The site makes **zero third-party requests**:

- **Fonts:** Self-hosted woff2 files in `css/fonts/` (no Google Fonts CDN)
- **Images:** Stored locally as WebP (no hotlinking to PhotoShelter CDN from the browser)
- **Search:** Redirects to PhotoShelter in a new tab (user-initiated navigation, not a background request)
- **No cookies** set by the site
- **No analytics or tracking**
- **No forms** collecting personal data
- Privacy policy link in footer points to `actionplus.co.uk/privacy/`

---

## External Dependencies

| Dependency | Purpose | Required |
|------------|---------|----------|
| Bebas Neue + DM Sans fonts (self-hosted woff2) | Typography | Yes (included in `css/fonts/`) |
| PHP GD Extension | WebP image conversion | Yes |
| PHP cURL Extension | Fetching gallery-list page + HEAD requests | Yes (or use wp_remote_get/wp_remote_head) |

---

## Source Files Reference

| Current File | Purpose | WordPress Equivalent |
|-------------|---------|---------------------|
| `index.html` | Homepage with grid | Shortcode output or page template |
| `css/style.css` | All styles | `assets/css/apsi-grid.css` (enqueued) |
| `css/fonts/*.woff2` | Self-hosted fonts (GDPR) | `assets/css/fonts/` (plugin asset) |
| `js/app.js` | Grid builder + search + cache-busting | `assets/js/apsi-grid.js` (enqueued) |
| `api/sync.php` | Gallery scraper + ETag checker | `includes/class-apsi-sync.php` (WP-Cron) |
| `api/config.php` | Configuration | WordPress options (admin settings page) |
| `galleries.json` | Gallery manifest | WordPress transient or file in uploads |
| `etags.json` | ETag cache for cover change detection | WordPress option or file in uploads |
| `images/*.webp` | Cached gallery covers | `wp-content/uploads/apsi/*.webp` |
| `images/logo.png` | Site logo | Theme asset or plugin asset |
| `.htaccess` | Cache-control headers | `send_headers` action in plugin |
| `404.html` | Custom 404 page with yellow card image | WordPress 404.php template |
| `images/404.webp` | Yellow card referee image for 404 page | Plugin/theme asset |
| `favicon.ico` / `favicon-32x32.png` / `apple-touch-icon.png` | Favicons | Theme asset |
| `robots.txt` | Blocks `/api/` from crawlers | WordPress/Yoast manages this |
| `sitemap.xml` | Homepage entry for search engines | WordPress/Yoast manages this |
