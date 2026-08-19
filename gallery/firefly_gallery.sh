#!/usr/bin/env bash
#
# firefly_gallery.sh - generate an HTML gallery page for a folder of
# Firefly-supported files (FITS images, VOTable/CSV/TSV/IPAC/parquet tables).
#
# The folder is assumed to be mounted inside a running Firefly server as
# /external, so each file is addressable server-side as /external/<relpath>.
#
# Usage:
#   ./firefly_gallery.sh <folder> [--firefly-url URL] [--out FILE]
#
# Defaults:
#   --firefly-url http://localhost:8080/firefly
#   --out         gallery.html
#
# Firefly docker requirements:
#   - mount the folder as /external:      -v /path/to/folder:/external
#   - csv/tsv/parquet are read via duckdb, which needs the folder allowed:
#       -e PROPS="duckdb.allowed.dirs=/external"
#   (FITS/VOTable/IPAC work without PROPS; /external is already in
#    visualize.fits.search.path by default)
#
# Example:
#   docker run -d -p 8080:8080 -m 4g -e PROPS="duckdb.allowed.dirs=/external" \
#          -v /path/to/folder:/external ipac/firefly:latest
#
set -euo pipefail

FIREFLY_URL="http://localhost:8080/firefly"
OUT="gallery.html"
FOLDER=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --firefly-url) FIREFLY_URL="$2"; shift 2 ;;
        --out)         OUT="$2";         shift 2 ;;
        -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             FOLDER="$1";      shift ;;
    esac
done

[[ -d "$FOLDER" ]] || { echo "error: folder '$FOLDER' not found" >&2; exit 1; }

# extension -> viewer kind
kind_of() {
    case "${1##*.}" in
        fits|fit|fz|FITS|FIT|FZ)                          echo image ;;
        vot|votable|xml|csv|tsv|tbl|ipac|parquet)         echo table ;;
        *)                                                echo "" ;;
    esac
}

file_size() {  # portable stat (macOS / linux)
    stat -f%z "$1" 2>/dev/null || stat -c%s "$1"
}

json_escape() {  # escape \ and " for JSON string values
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# ---- build manifest -------------------------------------------------------
MANIFEST="["
sep=""
count=0
for f in "$FOLDER"/*; do
    [[ -f "$f" ]] || continue
    kind=$(kind_of "$f")
    [[ -n "$kind" ]] || continue
    name=$(basename "$f")
    size=$(file_size "$f")
    MANIFEST+="$sep{\"name\":\"$(json_escape "$name")\",\"relpath\":\"$(json_escape "$name")\",\"kind\":\"$kind\",\"size\":$size}"
    sep=","
    count=$((count + 1))
done
MANIFEST+="]"

[[ $count -gt 0 ]] || { echo "error: no supported files found in '$FOLDER'" >&2; exit 1; }
echo "found $count supported file(s) in $FOLDER"

# ---- emit HTML ------------------------------------------------------------
cat > "$OUT" <<EOF
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Firefly Gallery</title>
<style>
  body   { font-family: -apple-system, Helvetica, Arial, sans-serif; margin: 1.5em; background:#fafafa; }
  h1     { font-size: 1.3em; }
  #cfg   { margin-bottom: 1em; }
  #cfg input { width: 28em; padding: 4px; }
  table  { border-collapse: collapse; background:#fff; }
  th, td { border: 1px solid #ccc; padding: 6px 10px; text-align: left; vertical-align: top; }
  th     { background: #eee; }
  .preview { width: 300px; height: 220px; overflow: hidden; background:#f2f2f2;
             display:flex; align-items:center; justify-content:center; color:#999; font-size:0.85em; }
  a.open { text-decoration:none; padding: 4px 10px; background:#1a66a8; color:#fff; border-radius:4px; }
  .err   { color:#b00; font-size:0.8em; }
</style>
</head>
<body>
<h1>Firefly Gallery</h1>
<div id="cfg">
  Firefly URL:
  <input id="ffurl" type="text">
  <button onclick="applyUrl()">Apply</button>
  <button onclick="resetUrl()">Reset to default</button>
</div>
<table>
  <thead><tr><th>Name</th><th>Kind</th><th>Size (bytes)</th><th>Preview</th><th></th></tr></thead>
  <tbody id="rows"></tbody>
</table>

<script>
const DEFAULT_FIREFLY = '${FIREFLY_URL}';
const MANIFEST = ${MANIFEST};

function fireflyUrl() {
    return (localStorage.getItem('fireflyUrl') || DEFAULT_FIREFLY).replace(/\/+\$/, '');
}
function applyUrl() {
    localStorage.setItem('fireflyUrl', document.getElementById('ffurl').value.trim());
    location.reload();
}
function resetUrl() {
    localStorage.removeItem('fireflyUrl');
    location.reload();
}
document.getElementById('ffurl').value = fireflyUrl();

// ---- build table rows ----
const tbody = document.getElementById('rows');
MANIFEST.forEach((item, i) => {
    // server rejects file:// uploads, so use the image/table api commands
    // which accept a server-side path directly
    const serverPath = encodeURIComponent('/external/' + item.relpath);
    const openUrl = item.kind === 'image'
        ? fireflyUrl() + '/?api=image&file=' + serverPath
        : fireflyUrl() + '/?api=table&source=' + serverPath;
    const tr = document.createElement('tr');
    tr.innerHTML =
        '<td>' + item.name + '</td>' +
        '<td>' + item.kind + '</td>' +
        '<td>' + item.size.toLocaleString() + '</td>' +
        '<td><div class="preview" id="prev-' + i + '">loading…</div></td>' +
        '<td><a class="open" href="' + openUrl + '" target="_blank">Open</a></td>';
    tbody.appendChild(tr);
});

// ---- lazy render previews with IntersectionObserver ----
let fireflyReady = false;
const pending = new Set();   // indices visible before firefly loaded
const rendered = new Set();

function renderPreview(i) {
    if (rendered.has(i)) return;
    rendered.add(i);
    const item = MANIFEST[i];
    const divId = 'prev-' + i;
    const serverPath = '/external/' + item.relpath;
    document.getElementById(divId).textContent = '';
    try {
        if (item.kind === 'image') {
            firefly.showImage(divId, {
                plotId: 'plot-' + i,
                file: serverPath,
                Title: item.name,
                ZoomType: 'TO_WIDTH_HEIGHT',
            });
        } else {
            const req = firefly.util.table.makeFileRequest(item.name, serverPath);
            firefly.showTable(divId, req, {
                selectable: false, showFilters: false, showUnits: false,
                showToolbar: false, showTitle: false, pageSize: 5,
            });
        }
    } catch (e) {
        document.getElementById(divId).innerHTML = '<span class="err">' + e + '</span>';
    }
}

const obs = new IntersectionObserver((entries) => {
    entries.forEach((en) => {
        if (!en.isIntersecting) return;
        const i = Number(en.target.id.replace('prev-', ''));
        obs.unobserve(en.target);
        fireflyReady ? renderPreview(i) : pending.add(i);
    });
}, { rootMargin: '100px' });
MANIFEST.forEach((_, i) => obs.observe(document.getElementById('prev-' + i)));

// ---- load firefly from configured server ----
window.onFireflyLoaded = function () {
    fireflyReady = true;
    pending.forEach(renderPreview);
    pending.clear();
};
(function loadFirefly() {
    const s = document.createElement('script');
    s.src = fireflyUrl() + '/firefly_loader.js';
    s.onerror = () => document.querySelectorAll('.preview').forEach(
        (d) => { d.innerHTML = '<span class="err">cannot load firefly_loader.js from ' + fireflyUrl() + '</span>'; });
    document.head.appendChild(s);
})();
</script>
</body>
</html>
EOF

echo "wrote $OUT (firefly: $FIREFLY_URL)"
