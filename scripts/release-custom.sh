#!/usr/bin/env bash
# 用法: scripts/release-custom.sh <版本号, 如 v1.1.0-custom.2> "<本版更新说明>"
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
NOTE="${2:-}"
if [[ -z "$TAG" || -z "$NOTE" ]]; then
  echo "用法: scripts/release-custom.sh <版本号, 如 v1.1.0-custom.2> \"<更新说明>\"" >&2
  exit 1
fi

DATE=$(date +%Y-%m-%d)
python3 - "$TAG" "$DATE" "$NOTE" << 'PY'
import sys
tag, date, note = sys.argv[1], sys.argv[2], sys.argv[3]
p = "CHANGELOG.md"
with open(p, "r", encoding="utf-8") as f:
    s = f.read()
entry = f"## [{tag}] - {date}\n- {note}\n\n"
marker = "## ["
idx = s.find(marker)
if idx != -1:
    s = s[:idx] + entry + s[idx:]
else:
    s = entry + s
with open(p, "w", encoding="utf-8") as f:
    f.write(s)
PY

git add -A
git commit -m "release(${TAG}): ${NOTE}"
git tag -f "${TAG}" -m "${TAG}: ${NOTE}"
git push -u origin main --tags
echo "✅ 已记录并推送版本 ${TAG} 至 GitHub (git@github.com:wangxi73/cicada.git)"
