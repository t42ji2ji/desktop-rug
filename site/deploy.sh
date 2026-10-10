#!/bin/sh
# 官網部署到 Cloudflare Pages 專案 desktop-rug（https://rug.dorara.app）
# CSS／JS 都寫在 index.html 裡，避開 dorara.app 網域的 4 小時瀏覽器快取
set -e
cd "$(dirname "$0")"
npx --yes wrangler pages deploy . --project-name desktop-rug --branch main --commit-dirty=true
