#!/usr/bin/env bash
# Builds the website and deploys it to the Cloudflare Worker "cicada-site" (static assets only), which
# serves cicada.indaloop.app. The custom domain is attached to the Worker in Cloudflare, so the config
# below declares no routes and a deploy leaves it alone. Needs `wrangler login` once.
set -euo pipefail
cd "$(dirname "$0")/.."

python3 scripts/site.py
CONFIG=$(mktemp -d)
trap 'rm -rf "$CONFIG"' EXIT
cat > "$CONFIG/wrangler.jsonc" <<JSON
{
  "name": "cicada-site",
  "compatibility_date": "2026-10-01",
  "assets": { "directory": "$PWD/build/site", "html_handling": "auto-trailing-slash" }
}
JSON
(cd "$CONFIG" && wrangler deploy --config wrangler.jsonc)
curl -fsS -o /dev/null "https://cicada.indaloop.app/?deployed=$(date +%s)" && echo "Live: https://cicada.indaloop.app/"
