<?php
// =============================================================
// PhotoShelter API Proxy
// Keeps the API key server-side. All client JS calls go through here.
// =============================================================

header('Content-Type: application/json; charset=utf-8');
header('Access-Control-Allow-Origin: *');
header('Access-Control-Allow-Methods: GET');

require_once __DIR__ . '/config.php';

$API_BASE = PS_BASE_URL . '/psapi/v4.0';

// Allowed proxy actions
$action = $_GET['action'] ?? '';

switch ($action) {

    // ---- Recent galleries with key images and links ----
    case 'galleries':
        $page     = max(1, intval($_GET['page'] ?? 1));
        $per_page = max(1, min(100, intval($_GET['per_page'] ?? 50)));
        $url = $API_BASE . '/galleries'
             . '?api_key='        . urlencode(PS_API_KEY)
             . '&org_id='         . urlencode(PS_ORG_ID)
             . '&sort_by=creation_time'
             . '&sort_direction=descending'
             . '&per_page='       . $per_page
             . '&page='           . $page
             . '&include=key-image,link';
        echo fetch_url($url);
        break;

    // ---- Gallery cover images (up to 4 thumbs) ----
    case 'gallery_cover':
        $id = $_GET['gallery_id'] ?? '';
        if (!preg_match('/^G[A-Za-z0-9._]+$/', $id)) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid gallery ID']);
            exit;
        }
        $url = $API_BASE . '/galleries/' . $id . '/cover'
             . '?api_key=' . urlencode(PS_API_KEY)
             . '&include=link';
        echo fetch_url($url);
        break;

    // ---- Gallery key image ----
    case 'gallery_key_image':
        $id = $_GET['gallery_id'] ?? '';
        if (!preg_match('/^G[A-Za-z0-9._]+$/', $id)) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid gallery ID']);
            exit;
        }
        $url = $API_BASE . '/galleries/' . $id . '/key-image'
             . '?api_key=' . urlencode(PS_API_KEY)
             . '&include=link';
        echo fetch_url($url);
        break;

    // ---- Media link (CDN URL for an image) ----
    case 'media_link':
        $id = $_GET['media_id'] ?? '';
        if (!preg_match('/^[A-Za-z0-9]+$/', $id)) {
            http_response_code(400);
            echo json_encode(['error' => 'Invalid media ID']);
            exit;
        }
        $size = $_GET['size'] ?? '600x400';
        $mode = $_GET['mode'] ?? 'fill';
        $url = $API_BASE . '/media/' . $id . '/link'
             . '?api_key='    . urlencode(PS_API_KEY)
             . '&image_size=' . urlencode($size)
             . '&image_mode=' . urlencode($mode);
        echo fetch_url($url);
        break;

    default:
        http_response_code(400);
        echo json_encode(['error' => 'Unknown action. Use: galleries, gallery_cover, gallery_key_image, media_link']);
        break;
}

// ---- cURL helper ----
function fetch_url($url) {
    $ch = curl_init($url);
    curl_setopt_array($ch, [
        CURLOPT_RETURNTRANSFER => true,
        CURLOPT_FOLLOWLOCATION => true,
        CURLOPT_TIMEOUT        => 15,
        CURLOPT_HTTPHEADER     => ['Accept: application/json'],
    ]);
    $response = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    $error    = curl_error($ch);
    curl_close($ch);

    if ($error) {
        http_response_code(502);
        return json_encode(['error' => 'Upstream request failed', 'detail' => $error]);
    }

    http_response_code($httpCode);
    return $response;
}
