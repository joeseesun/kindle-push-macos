#!/bin/zsh
# Publish site/ to https://kindle.qiaomu.ai (Nginx static root on the Qiaomu VPS, ssh alias `myvps`).
# Vhost: /www/server/panel/vhost/nginx/kindle.qiaomu.ai.conf · TLS: Let's Encrypt via certbot webroot.
set -euo pipefail
cd "$(dirname "$0")/.."
if grep -q "__UMAMI_ID__" site/index.html || ! grep -Eq 'data-website-id="[0-9a-f-]{36}"' site/index.html; then
  echo "site/index.html: missing Umami website ID" >&2; exit 1
fi
rsync -az --delete --exclude .DS_Store site/ myvps:/www/wwwroot/kindle.qiaomu.ai/
ssh myvps 'chown -R www:www /www/wwwroot/kindle.qiaomu.ai' >/dev/null
curl -fsS -o /dev/null -w "kindle.qiaomu.ai %{http_code}\n" https://kindle.qiaomu.ai/
