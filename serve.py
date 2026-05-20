#!/usr/bin/env python3
"""
Local dev server for APSI site.
  python3 serve.py --sync     Scrape gallery-list, download new images, write galleries.json
  python3 serve.py            Start local web server on port 8000
"""

import http.server
import html as html_mod
import json
import os
import re
import sys
import urllib.request
import urllib.error
from datetime import datetime
from pathlib import Path

PORT = 8000
ROOT = Path(__file__).parent

PS_BASE_URL = 'https://actionplusps.photoshelter.com'
GALLERY_LIST_URL = PS_BASE_URL + '/gallery-list'


def fetch_etag(url):
    """HEAD request to get ETag header without downloading the image."""
    req = urllib.request.Request(url, method='HEAD', headers={'User-Agent': 'APSI-Sync/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            etag = resp.headers.get('ETag', '').strip('"')
            return etag if etag else None
    except Exception:
        return None


def fetch(url):
    req = urllib.request.Request(url, headers={'User-Agent': 'APSI-Sync/1.0'})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.read()
    except Exception as e:
        print(f"  Fetch error: {e}")
        return None


def sync_galleries():
    image_dir = ROOT / 'images'
    image_dir.mkdir(exist_ok=True)
    json_file = ROOT / 'galleries.json'

    # Load existing manifest
    existing = {}
    if json_file.exists():
        manifest = json.loads(json_file.read_text())
        for g in manifest.get('galleries', []):
            existing[g['id']] = g
    print(f"Existing galleries in manifest: {len(existing)}")

    # Fetch public gallery-list page
    print(f"Fetching {GALLERY_LIST_URL}...")
    raw = fetch(GALLERY_LIST_URL)
    if not raw:
        print("ERROR: Failed to fetch gallery-list page")
        sys.exit(1)
    page_html = raw.decode('utf-8', errors='replace')

    # Parse galleries from HTML
    pattern = r'<a\s+href="([^"]*\/gallery\/[^"]+\/(G[A-Za-z0-9._]+)\/?)"[^>]*>\s*<img\s+src="([^"]+)"[^>]*alt="([^"]*)"[^>]*>'
    matches = re.findall(pattern, page_html, re.IGNORECASE)

    if not matches:
        print("ERROR: No galleries found on page")
        sys.exit(1)

    # Parse image counts from gallery list
    image_counts = {}
    count_pattern = r'(G[A-Za-z0-9._]+)/?"[^>]*class="gallery_list_name"[^>]*>.*?<span class="gallery_list_num_images">(\d+)\s*images?</span>'
    for gid, num in re.findall(count_pattern, page_html, re.IGNORECASE | re.DOTALL):
        image_counts[gid] = int(num)

    # Deduplicate by gallery ID, preserve order
    scraped = {}
    scraped_order = []
    for gallery_url, gallery_id, image_url, name in matches:
        if gallery_id not in scraped:
            scraped[gallery_id] = {
                'id': gallery_id,
                'name': html_mod.unescape(name),
                'url': gallery_url,
                'image_url': image_url,
                'num_images': image_counts.get(gallery_id, 0),
            }
            scraped_order.append(gallery_id)

    print(f"Scraped {len(scraped)} unique galleries from page")

    # Load ETag cache
    etag_file = ROOT / 'etags.json'
    etags = {}
    if etag_file.exists():
        etags = json.loads(etag_file.read_text())

    # Find new galleries
    new_ids = [gid for gid in scraped_order if gid not in existing]

    # Check existing galleries for updated covers via HEAD request
    updated_ids = []
    for gid in scraped_order:
        if gid in existing and gid in etags:
            large_url = re.sub(r'/t/\d+/', '/s/1200/', scraped[gid]['image_url'])
            remote_etag = fetch_etag(large_url + '?t=' + str(int(__import__('time').time())))
            if remote_etag and remote_etag != etags[gid]:
                updated_ids.append(gid)

    # Always update num_images for existing galleries
    for gid in scraped_order:
        if gid in existing:
            existing[gid]['num_images'] = scraped[gid].get('num_images', 0)

    to_download = new_ids + updated_ids

    if not to_download:
        # Still save manifest to update num_images
        ordered = [existing[gid] for gid in scraped_order if gid in existing]
        manifest = {'updated': datetime.now().isoformat(), 'count': len(ordered), 'galleries': ordered}
        json_file.write_text(json.dumps(manifest, indent=2))
        print("No new or updated galleries. Updated image counts.")
        return

    if new_ids:
        print(f"{len(new_ids)} new gallery(s)")
    if updated_ids:
        print(f"{len(updated_ids)} updated cover(s)")

    # Download images for new and updated galleries
    from PIL import Image as PILImage
    import io as _io

    downloaded = 0
    for gid in to_download:
        g = scraped[gid]
        is_new = gid in new_ids
        print(f"  {'NEW' if is_new else 'UPDATED'}: {g['name']}")

        filename = f"{gid}.webp"
        filepath = image_dir / filename

        large_url = re.sub(r'/t/\d+/', '/s/1200/', g['image_url'])
        large_url += '?t=' + str(int(__import__('time').time()))

        img_data = fetch(large_url)
        if img_data and len(img_data) > 0:
            src = PILImage.open(_io.BytesIO(img_data))
            src.save(str(filepath), 'WEBP', quality=84)
            existing[gid] = {
                'id': gid,
                'name': g['name'],
                'url': g['url'],
                'image': f"images/{filename}",
                'num_images': g.get('num_images', 0),
            }
            remote_etag = fetch_etag(large_url)
            if remote_etag:
                etags[gid] = remote_etag
            downloaded += 1
        else:
            print("    WARN: Failed to download image")

    print(f"Downloaded {downloaded} image(s)")

    # Save ETag cache
    etag_file.write_text(json.dumps(etags, indent=2))

    # Rebuild manifest in scraped order (newest first)
    ordered = [existing[gid] for gid in scraped_order if gid in existing]

    manifest = {
        'updated': datetime.now().isoformat(),
        'count': len(ordered),
        'galleries': ordered,
    }

    json_file.write_text(json.dumps(manifest, indent=2))
    print(f"Updated galleries.json with {len(ordered)} galleries")

    # Clean up old images and stale ETags
    active_ids = set(scraped.keys())
    removed = 0
    for f in image_dir.glob('G*.webp'):
        file_id = f.stem
        if file_id not in active_ids:
            f.unlink()
            removed += 1
            print(f"  REMOVED: {file_id} (no longer on gallery-list)")
    if removed > 0:
        print(f"Cleaned up {removed} old image(s)")

    # Clean stale ETags
    for eid in list(etags.keys()):
        if eid not in active_ids:
            del etags[eid]
    etag_file.write_text(json.dumps(etags, indent=2))

    print("Done.")


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)


import threading

class ThreadedHTTPServer(http.server.HTTPServer):
    """Handle each request in a separate thread."""
    def process_request(self, request, client_address):
        thread = threading.Thread(target=self.process_request_thread, args=(request, client_address))
        thread.daemon = True
        thread.start()

    def process_request_thread(self, request, client_address):
        try:
            self.finish_request(request, client_address)
        except Exception:
            self.handle_error(request, client_address)
        finally:
            self.shutdown_request(request)


def serve():
    print(f"Serving APSI at http://localhost:{PORT}")
    print("Press Ctrl+C to stop")
    with ThreadedHTTPServer(('', PORT), Handler) as server:
        server.serve_forever()


if __name__ == '__main__':
    if '--sync' in sys.argv:
        sync_galleries()
    else:
        serve()
