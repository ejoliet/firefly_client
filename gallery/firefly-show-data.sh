#!/usr/bin/env bash
set -euo pipefail

FIREFLY_URL="${FIREFLY_URL:-http://localhost:8080/firefly}"
PREVIEW_METADATA=false
TITLE=""

usage() {
  cat <<'EOF'
Usage:
  firefly-show-data.sh [--preview] [--title TITLE] FILE

Environment:
  FIREFLY_URL   Firefly server URL. Default: http://localhost:8080/firefly

Examples:
  ./firefly-show-data.sh image.fits
  ./firefly-show-data.sh --preview table.tbl
  FIREFLY_URL=http://localhost:8080/firefly ./firefly-show-data.sh --title "My FITS" data.fits
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --preview)
      PREVIEW_METADATA=true
      shift
      ;;
    --title)
      [[ $# -ge 2 ]] || { echo "error: --title requires a value" >&2; exit 2; }
      TITLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      break
      ;;
  esac
done

[[ $# -eq 1 ]] || { usage >&2; exit 2; }

FILE="$1"

[[ -f "$FILE" ]] || { echo "error: file not found: $FILE" >&2; exit 1; }
[[ -r "$FILE" ]] || { echo "error: file is not readable: $FILE" >&2; exit 1; }

uv run --no-project --with firefly-client>=3.2 python - "$FIREFLY_URL" "$FILE" "$PREVIEW_METADATA" "$TITLE" <<'PY'
import sys

url, path, preview, title = sys.argv[1:5]
preview_metadata = preview.lower() == "true"
title = title or None

try:
    from firefly_client import FireflyClient
except ImportError:
    raise SystemExit(
        "error: firefly_client is not installed.\n"
        "Install it with:\n"
        "  python3 -m pip install firefly-client"
    )

# Prefer the current helper when available.
if hasattr(FireflyClient, "make_client"):
    fc = FireflyClient.make_client(url=url)
else:
    # Older/direct constructor requires an explicit channel.
    fc = FireflyClient(url, channel=None)

try:
    fc.launch_browser()
except Exception as exc:
    print(f"warning: could not launch browser automatically: {exc}", file=sys.stderr)
    try:
        print(f"Firefly URL: {fc.display_url()}")
    except Exception:
        print(f"Firefly URL: {url}")

result = fc.show_data(
    path,
    preview_metadata=preview_metadata,
    title=title,
)

print(result)
PY
