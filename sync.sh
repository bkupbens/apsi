#!/bin/bash
# =============================================================
#   APSI Gallery Sync — Bash version (compatible with bash 3+)
#   Scrapes PhotoShelter gallery-list, downloads cover images,
#   converts to WebP via ImageMagick, and writes galleries.json
#
#   Usage:  bash sync.sh
#   Cron:   23 * * * * cd /path/to/apsi && bash sync.sh >> /tmp/apsi-sync.log 2>&1
#
#   Requirements: curl, sed, awk, ImageMagick (convert), bash 3+
# =============================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
IMAGE_DIR="$SCRIPT_DIR/images"
JSON_FILE="$SCRIPT_DIR/galleries.json"
ETAG_FILE="$SCRIPT_DIR/etags.json"
TMP_DIR="$SCRIPT_DIR/.sync_tmp"

PS_GALLERY_LIST="https://actionplusps.photoshelter.com/gallery-list"
USER_AGENT="APSI-Sync/1.0"

mkdir -p "$IMAGE_DIR" "$TMP_DIR"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# --- Fetch gallery-list page ---

log "Fetching $PS_GALLERY_LIST..."
PAGE_FILE="$TMP_DIR/page.html"
if ! curl -s -A "$USER_AGENT" --max-time 30 -o "$PAGE_FILE" "$PS_GALLERY_LIST" 2>/dev/null || [ ! -s "$PAGE_FILE" ]; then
    log "ERROR: Failed to fetch gallery-list page"
    rm -rf "$TMP_DIR"
    exit 1
fi

# --- Parse galleries using a single awk pass ---
# Output TSV: gallery_id \t gallery_url \t image_url \t name \t num_images

SCRAPED_FILE="$TMP_DIR/scraped.tsv"
EXISTING_FILE="$TMP_DIR/existing.tsv"

# Flatten HTML to make parsing easier, then use awk to extract per-<li> data
tr '\n\r' '  ' < "$PAGE_FILE" | sed 's/<li>/\n<li>/g' > "$TMP_DIR/lines.txt"

awk '
/<li>/ {
    line = $0

    # Extract gallery URL and ID
    gallery_url = ""
    gid = ""
    if (match(line, /href="[^"]*\/gallery\/[^"]*"/)) {
        gallery_url = substr(line, RSTART+6, RLENGTH-7)
        # Extract GID from URL
        n = split(gallery_url, parts, "/")
        for (i=1; i<=n; i++) {
            if (parts[i] ~ /^G[A-Za-z0-9._]+$/) gid = parts[i]
        }
    }
    if (gid == "") next

    # Skip duplicates
    if (gid in seen) next
    seen[gid] = 1

    # Extract image src
    image_url = ""
    if (match(line, /src="[^"]*"/)) {
        image_url = substr(line, RSTART+5, RLENGTH-6)
    }
    if (image_url == "") next

    # Extract alt text
    name = ""
    if (match(line, /alt="[^"]*"/)) {
        name = substr(line, RSTART+5, RLENGTH-6)
    }
    # Decode HTML entities
    gsub(/&amp;/, "\\&", name)
    gsub(/&lt;/, "<", name)
    gsub(/&gt;/, ">", name)
    gsub(/&quot;/, "\"", name)

    # Extract image count
    num = 0
    if (match(line, /gallery_list_num_images">[0-9]+/)) {
        s = substr(line, RSTART)
        match(s, />[0-9]+/)
        num = substr(s, RSTART+1, RLENGTH-1) + 0
    }

    print gid "\t" gallery_url "\t" image_url "\t" name "\t" num
}
' "$TMP_DIR/lines.txt" > "$SCRAPED_FILE"

total_scraped=$(wc -l < "$SCRAPED_FILE" | tr -d ' ')

if [ "$total_scraped" -eq 0 ]; then
    log "ERROR: No galleries found on page"
    rm -rf "$TMP_DIR"
    exit 1
fi

log "Scraped $total_scraped unique galleries from page"

# --- Load existing manifest into TSV ---

if [ -f "$JSON_FILE" ]; then
    awk '
    BEGIN { id=""; name=""; url=""; image=""; num=0 }
    /"id"/ { gsub(/.*"id"[[:space:]]*:[[:space:]]*"/, ""); gsub(/".*/, ""); id=$0 }
    /"name"/ { gsub(/.*"name"[[:space:]]*:[[:space:]]*"/, ""); gsub(/"[[:space:]]*,?$/, ""); name=$0 }
    /"url"/ { gsub(/.*"url"[[:space:]]*:[[:space:]]*"/, ""); gsub(/"[[:space:]]*,?$/, ""); url=$0 }
    /"image"/ { gsub(/.*"image"[[:space:]]*:[[:space:]]*"/, ""); gsub(/"[[:space:]]*,?$/, ""); image=$0 }
    /"num_images"/ { gsub(/.*"num_images"[[:space:]]*:[[:space:]]*/, ""); gsub(/[^0-9].*/, ""); num=$0 }
    /\}/ { if (id != "") { print id "\t" name "\t" url "\t" image "\t" num; id=""; name=""; url=""; image=""; num=0 } }
    ' "$JSON_FILE" > "$EXISTING_FILE"
else
    touch "$EXISTING_FILE"
fi

existing_count=$(wc -l < "$EXISTING_FILE" | tr -d ' ')
log "Existing galleries in manifest: $existing_count"

# --- Determine new and updated galleries ---

DOWNLOAD_FILE="$TMP_DIR/to_download.txt"
> "$DOWNLOAD_FILE"

new_count=0
updated_count=0

while IFS=$'\t' read -r gid gallery_url image_url name num_images; do
    if ! grep -q "^${gid}	" "$EXISTING_FILE" 2>/dev/null; then
        echo "$gid" >> "$DOWNLOAD_FILE"
        new_count=$((new_count + 1))
    else
        if [ -f "$ETAG_FILE" ]; then
            old_etag=$(grep "\"${gid}\"" "$ETAG_FILE" 2>/dev/null | sed 's/.*:[[:space:]]*"//;s/"[[:space:]]*,*//' | head -1)
            if [ -n "$old_etag" ]; then
                large_url=$(echo "$image_url" | sed 's|/t/[0-9]*/|/s/1200/|')
                remote_etag=$(curl -sI -A "$USER_AGENT" --max-time 10 "${large_url}?t=$(date +%s)" 2>/dev/null | grep -i '^etag:' | sed 's/[Ee][Tt][Aa][Gg]:[[:space:]]*"//;s/".*//;s/\r//')
                if [ -n "$remote_etag" ] && [ "$remote_etag" != "$old_etag" ]; then
                    echo "$gid" >> "$DOWNLOAD_FILE"
                    updated_count=$((updated_count + 1))
                fi
            fi
        fi
    fi
done < "$SCRAPED_FILE"

[ $new_count -gt 0 ] && log "$new_count new gallery(s)"
[ $updated_count -gt 0 ] && log "$updated_count updated cover(s)"

# --- Download and convert images ---

downloaded=0
ETAG_TMP="$TMP_DIR/etags_new.tsv"
> "$ETAG_TMP"

# Copy existing etags
if [ -f "$ETAG_FILE" ]; then
    grep '"G[A-Za-z0-9._]*"' "$ETAG_FILE" 2>/dev/null | while IFS= read -r line; do
        key=$(echo "$line" | sed 's/.*"\(G[A-Za-z0-9._]*\)".*/\1/')
        val=$(echo "$line" | sed 's/.*:[[:space:]]*"//;s/"[[:space:]]*,*$//')
        [ -n "$key" ] && [ -n "$val" ] && echo "${key}	${val}"
    done > "$ETAG_TMP"
fi

while IFS= read -r gid; do
    [ -z "$gid" ] && continue

    line=$(grep "^${gid}	" "$SCRAPED_FILE" | head -1)
    image_url=$(echo "$line" | cut -f3)
    name=$(echo "$line" | cut -f4)

    is_new="UPDATED"
    grep -q "^${gid}	" "$EXISTING_FILE" 2>/dev/null || is_new="NEW"
    log "  $is_new: $name"

    large_url=$(echo "$image_url" | sed 's|/t/[0-9]*/|/s/1200/|')
    large_url="${large_url}?t=$(date +%s)"

    tmp_file="$TMP_DIR/${gid}.jpg"
    out_file="$IMAGE_DIR/${gid}.webp"

    if curl -s -A "$USER_AGENT" --max-time 30 -o "$tmp_file" "$large_url" 2>/dev/null && [ -s "$tmp_file" ]; then
        converted=false
        if command -v convert >/dev/null 2>&1; then
            convert "$tmp_file" -quality 84 "$out_file" 2>/dev/null && converted=true
        else
            # Fallback: copy as-is (will be JPEG with .webp extension)
            cp "$tmp_file" "$out_file" && converted=true
        fi
        if [ "$converted" = true ]; then
            # Update existing entry
            grep -v "^${gid}	" "$EXISTING_FILE" > "$TMP_DIR/existing_tmp.tsv" 2>/dev/null || true
            gallery_url=$(echo "$line" | cut -f2)
            num_images=$(echo "$line" | cut -f5)
            echo "${gid}	${name}	${gallery_url}	images/${gid}.webp	${num_images}" >> "$TMP_DIR/existing_tmp.tsv"
            mv "$TMP_DIR/existing_tmp.tsv" "$EXISTING_FILE"

            # Update ETag
            remote_etag=$(curl -sI -A "$USER_AGENT" --max-time 10 "$large_url" 2>/dev/null | grep -i '^etag:' | sed 's/[Ee][Tt][Aa][Gg]:[[:space:]]*"//;s/".*//;s/\r//')
            if [ -n "$remote_etag" ]; then
                grep -v "^${gid}	" "$ETAG_TMP" > "$TMP_DIR/etag_tmp2.tsv" 2>/dev/null || true
                echo "${gid}	${remote_etag}" >> "$TMP_DIR/etag_tmp2.tsv"
                mv "$TMP_DIR/etag_tmp2.tsv" "$ETAG_TMP"
            fi

            downloaded=$((downloaded + 1))
        else
            log "    WARN: Image conversion failed"
        fi
        rm -f "$tmp_file"
    else
        log "    WARN: Failed to download image"
        rm -f "$tmp_file"
    fi
done < "$DOWNLOAD_FILE"

log "Downloaded $downloaded image(s)"

# --- Update num_images for existing galleries ---

while IFS=$'\t' read -r gid gallery_url image_url name num_images; do
    if grep -q "^${gid}	" "$EXISTING_FILE" 2>/dev/null; then
        old_line=$(grep "^${gid}	" "$EXISTING_FILE" | head -1)
        old_name=$(echo "$old_line" | cut -f2)
        old_url=$(echo "$old_line" | cut -f3)
        old_image=$(echo "$old_line" | cut -f4)
        grep -v "^${gid}	" "$EXISTING_FILE" > "$TMP_DIR/existing_tmp.tsv" 2>/dev/null || true
        echo "${gid}	${old_name}	${old_url}	${old_image}	${num_images}" >> "$TMP_DIR/existing_tmp.tsv"
        mv "$TMP_DIR/existing_tmp.tsv" "$EXISTING_FILE"
    fi
done < "$SCRAPED_FILE"

# --- Build galleries.json in scraped order ---

{
    echo '{'
    printf '  "updated": "%s",\n' "$(date -u '+%Y-%m-%dT%H:%M:%S')"
    printf '  "count": %s,\n' "$total_scraped"
    echo '  "galleries": ['

    first=true
    while IFS=$'\t' read -r gid gallery_url image_url name num_images; do
        existing_line=$(grep "^${gid}	" "$EXISTING_FILE" 2>/dev/null | head -1)
        [ -z "$existing_line" ] && continue

        e_name=$(echo "$existing_line" | cut -f2)
        e_url=$(echo "$existing_line" | cut -f3)
        e_image=$(echo "$existing_line" | cut -f4)
        e_num=$(echo "$existing_line" | cut -f5)

        if [ "$first" = true ]; then
            first=false
        else
            echo ','
        fi

        safe_name=$(echo "$e_name" | sed 's/"/\\"/g')

        printf '    {\n'
        printf '      "id": "%s",\n' "$gid"
        printf '      "name": "%s",\n' "$safe_name"
        printf '      "url": "%s",\n' "$e_url"
        printf '      "image": "%s",\n' "$e_image"
        printf '      "num_images": %s\n' "${e_num:-0}"
        printf '    }'
    done < "$SCRAPED_FILE"

    echo ''
    echo '  ]'
    echo '}'
} > "$JSON_FILE"

log "Updated galleries.json with $total_scraped galleries"

# --- Clean up old images ---

removed=0
for f in "$IMAGE_DIR"/G*.webp; do
    [ -f "$f" ] || continue
    file_id=$(basename "$f" .webp)
    if ! grep -q "^${file_id}	" "$SCRAPED_FILE" 2>/dev/null; then
        rm -f "$f"
        removed=$((removed + 1))
        log "  REMOVED: $file_id (no longer on gallery-list)"
    fi
done
[ $removed -gt 0 ] && log "Cleaned up $removed old image(s)"

# --- Save ETag cache ---

{
    echo '{'
    first=true
    while IFS=$'\t' read -r gid etag; do
        grep -q "^${gid}	" "$SCRAPED_FILE" 2>/dev/null || continue
        if [ "$first" = true ]; then
            first=false
        else
            echo ','
        fi
        printf '  "%s": "%s"' "$gid" "$etag"
    done < "$ETAG_TMP"
    echo ''
    echo '}'
} > "$ETAG_FILE"

# --- Cleanup ---

rm -rf "$TMP_DIR"
log "Done."
