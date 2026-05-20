<?php
// =============================================================
// PhotoShelter Gallery Sync (No API Key Required)
// Scrapes the public gallery-list page, downloads new cover images.
// Cron: */10 * * * * php /path/to/apsi/api/sync.php
// =============================================================

require_once __DIR__ . '/config.php';

$GALLERY_LIST_URL = PS_BASE_URL . '/gallery-list';
$SITE_ROOT  = dirname(__DIR__);
$IMAGE_DIR  = $SITE_ROOT . '/images';
$JSON_FILE  = $SITE_ROOT . '/galleries.json';

// Ensure images directory exists
if (!is_dir($IMAGE_DIR)) {
    mkdir($IMAGE_DIR, 0755, true);
}

// ---- Step 1: Load existing manifest ----
$existing = [];
if (file_exists($JSON_FILE)) {
    $manifest = json_decode(file_get_contents($JSON_FILE), true);
    if ($manifest && !empty($manifest['galleries'])) {
        foreach ($manifest['galleries'] as $g) {
            $existing[$g['id']] = $g;
        }
    }
}
log_msg("Existing galleries in manifest: " . count($existing));

// ---- Step 2: Fetch public gallery-list page ----
log_msg("Fetching gallery-list from " . $GALLERY_LIST_URL);
$html = fetch_url($GALLERY_LIST_URL);
if ($html === false) {
    $msg = "APSI Sync failed: Could not fetch gallery-list page at $GALLERY_LIST_URL";
    log_msg("ERROR: " . $msg);
    send_alert($msg);
    exit(1);
}

// ---- Step 3: Parse galleries from HTML ----
// Pattern: <a href="...photoshelter.com/gallery/{name}/{id}/"><img src="{cdn_url}" ... alt="{title}">
$pattern = '/<a\s+href="([^"]*\/gallery\/[^"]+\/([G][A-Za-z0-9._]+)\/?)"[^>]*>\s*<img\s+src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>/i';
preg_match_all($pattern, $html, $matches, PREG_SET_ORDER);

if (empty($matches)) {
    $msg = "APSI Sync found 0 galleries on the gallery-list page. PhotoShelter may have changed their HTML structure. The scraping regex needs to be updated.";
    log_msg("ERROR: " . $msg);
    send_alert($msg);
    exit(1);
}

// Deduplicate by gallery ID (page has duplicate links)
$scraped = [];
foreach ($matches as $m) {
    $galleryUrl = $m[1];
    $galleryId  = $m[2];
    $imageUrl   = $m[3];
    $name       = html_entity_decode($m[4], ENT_QUOTES, 'UTF-8');

    if (!isset($scraped[$galleryId])) {
        $scraped[$galleryId] = [
            'id'       => $galleryId,
            'name'     => $name,
            'url'      => $galleryUrl,
            'imageUrl' => $imageUrl,
        ];
    }
}

log_msg("Scraped " . count($scraped) . " unique galleries from page");

// ---- Step 4: Load ETag cache ----
$ETAG_FILE = $SITE_ROOT . '/etags.json';
$etags = [];
if (file_exists($ETAG_FILE)) {
    $etags = json_decode(file_get_contents($ETAG_FILE), true) ?: [];
}

// ---- Step 5: Find new galleries and check for updated covers ----
$newIds = array_diff(array_keys($scraped), array_keys($existing));
$updatedIds = [];

// Check existing galleries for cover image changes via HEAD request
foreach ($scraped as $gid => $g) {
    if (isset($existing[$gid]) && isset($etags[$gid])) {
        $largeUrl = preg_replace('/\/t\/\d+\//', '/s/1200/', $g['imageUrl']);
        $remoteEtag = fetch_etag($largeUrl . '?t=' . time());
        if ($remoteEtag && $remoteEtag !== $etags[$gid]) {
            $updatedIds[] = $gid;
        }
    }
}

$toDownload = array_merge($newIds, $updatedIds);

if (empty($toDownload)) {
    log_msg("No new or updated galleries. Nothing to do.");
    exit(0);
}

if (!empty($newIds)) {
    log_msg(count($newIds) . " new gallery(s)");
}
if (!empty($updatedIds)) {
    log_msg(count($updatedIds) . " updated cover(s)");
}

// ---- Step 6: Download images for new and updated galleries ----
$downloaded = 0;

foreach ($toDownload as $gid) {
    $g = $scraped[$gid];
    $isNew = in_array($gid, $newIds);
    log_msg("  " . ($isNew ? "NEW" : "UPDATED") . ": {$g['name']}");

    $filename = $gid . '.webp';
    $filepath = $IMAGE_DIR . '/' . $filename;

    // Get a larger version of the thumbnail by adjusting the URL size parameter
    $largeUrl = preg_replace('/\/t\/\d+\//', '/s/1200/', $g['imageUrl']);
    $largeUrl .= '?t=' . time(); // Cache-buster to bypass CDN cache

    $imgData = fetch_url($largeUrl);
    if ($imgData !== false && strlen($imgData) > 0) {
        // Convert to WebP
        $srcImg = imagecreatefromstring($imgData);
        if ($srcImg) {
            imagewebp($srcImg, $filepath, 84);
            imagedestroy($srcImg);
        } else {
            file_put_contents($filepath, $imgData);
        }
        $existing[$gid] = [
            'id'    => $gid,
            'name'  => $g['name'],
            'url'   => $g['url'],
            'image' => 'images/' . $filename,
        ];
        // Store ETag for future change detection
        $remoteEtag = fetch_etag($largeUrl);
        if ($remoteEtag) {
            $etags[$gid] = $remoteEtag;
        }
        $downloaded++;
    } else {
        log_msg("    WARN: Failed to download image");
    }
}

log_msg("Downloaded $downloaded image(s)");

// Save ETag cache
file_put_contents($ETAG_FILE, json_encode($etags, JSON_PRETTY_PRINT));

// ---- Step 7: Rebuild manifest with scraped order (newest first) ----
$orderedGalleries = [];
foreach ($scraped as $gid => $g) {
    if (isset($existing[$gid])) {
        $orderedGalleries[] = $existing[$gid];
    }
}

$manifest = [
    'updated'   => date('c'),
    'count'     => count($orderedGalleries),
    'galleries' => $orderedGalleries,
];

file_put_contents($JSON_FILE, json_encode($manifest, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
log_msg("Updated galleries.json with " . count($orderedGalleries) . " galleries");

// ---- Step 8: Clean up old images no longer on the gallery-list page ----
$activeIds = array_flip(array_keys($scraped));
$removed = 0;
foreach (glob($IMAGE_DIR . '/G*.webp') as $file) {
    $fileId = basename($file, '.webp');
    if (!isset($activeIds[$fileId])) {
        unlink($file);
        $removed++;
        log_msg("  REMOVED: $fileId (no longer on gallery-list)");
    }
}
if ($removed > 0) {
    log_msg("Cleaned up $removed old image(s)");
}

// Also clean up stale ETags
foreach (array_keys($etags) as $etagId) {
    if (!isset($activeIds[$etagId])) {
        unset($etags[$etagId]);
    }
}
file_put_contents($ETAG_FILE, json_encode($etags, JSON_PRETTY_PRINT));

log_msg("Done.");

// ============================================================= Helpers

function fetch_etag($url) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_NOBODY         => true,
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_TIMEOUT        => 10,
        CURLOPT_USERAGENT      => 'APSI-Sync/1.0',
        CURLOPT_HEADER         => true,
    ]);
    $headers = curl_exec($ch);
    curl_close($ch);

    if (preg_match('/ETag:\s*"?([^"\r\n]+)"?/i', $headers, $m)) {
        return trim($m[1]);
    }
    return null;
}

function fetch_url($url) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_TIMEOUT        => 30,
        CURLOPT_USERAGENT      => 'APSI-Sync/1.0',
    ]);
    $response = curl_exec($ch);
    $error    = curl_error($ch);
    curl_close($ch);

    if ($error) {
        log_msg("  cURL error: $error");
        return false;
    }
    return $response;
}

function send_alert($message) {
    if (!defined('ALERT_EMAIL') || empty(ALERT_EMAIL)) return;
    $subject = 'APSI Sync Alert — Action Required';
    $headers = "From: APSI Sync <noreply@actionplus.co.uk>\r\n";
    $body = "The APSI gallery sync script encountered a problem:\n\n"
          . $message . "\n\n"
          . "Time: " . date('Y-m-d H:i:s T') . "\n"
          . "Server: " . gethostname() . "\n";
    mail(ALERT_EMAIL, $subject, $body, $headers);
    log_msg("Alert email sent to " . ALERT_EMAIL);
}

function log_msg($msg) {
    $ts = date('Y-m-d H:i:s');
    echo "[$ts] $msg\n";
}
