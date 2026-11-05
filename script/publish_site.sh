#!/usr/bin/env bash
# 发版后同步 kindle.qiaomu.ai：把 GitHub 最新 release 的版本号、DMG 大小、首屏「新增」
# 写进 site/index.html 的静态兜底文字和 JSON-LD，然后部署。
# 下载链接不动：始终是 releases/latest/download/KindlePush.dmg（发版时必须上传这个固定文件名）。
# 页面里的 app.js 运行时也会读最新 release，这一步只是让首屏 HTML、搜索引擎看到的也是新版。
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=joeseesun/kindle-push-macos

gh release view -R "$REPO" --json tagName,body,assets > /tmp/kindle-site-release.json
python3 - /tmp/kindle-site-release.json <<'PY'
import json, re, sys, html
rel = json.load(open(sys.argv[1]))
tag = rel["tagName"]; ver = tag.lstrip("v")
dmg = next((a for a in rel["assets"] if a["name"] == "KindlePush.dmg"), None)
if not dmg:
    sys.exit("最新 release 没有 KindlePush.dmg，网站下载会 404，先补传再同步")
size = f'{dmg["size"] / 1048576:.1f} MB'
zh = re.split(r"^## English", rel["body"] or "", flags=re.M)[0]
m = re.search(r"^- \*\*(.+?)\*\*", zh, flags=re.M)

p = "site/index.html"; s = open(p, encoding="utf-8").read(); old = s
s = re.sub(r'"softwareVersion": "[^"]+"', f'"softwareVersion": "{ver}"', s)
s = re.sub(r"<span data-ver>[^<]*</span>", f"<span data-ver>{tag}</span>", s)
s = re.sub(r"<span data-size>[^<]*</span>", f"<span data-size>{size}</span>", s)
if m:
    news = html.escape(f"{ver} 新增：{m.group(1).rstrip('：:')}")
    s = re.sub(r"<span data-news>[^<]*</span>", f"<span data-news>{news}</span>", s)
open(p, "w", encoding="utf-8").write(s)
print(f"site 同步到 {tag}，DMG {size}" + ("" if s != old else "（无变化）"))
PY

if ! git diff --quiet -- site/index.html; then
  git add site/index.html
  git commit -qm "site: sync to $(gh release view -R "$REPO" --json tagName -q .tagName)"
  echo "已提交 site/index.html，记得 git push"
fi
./script/deploy_site.sh
code=$(curl -sIL -o /dev/null -w '%{http_code}' "https://github.com/$REPO/releases/latest/download/KindlePush.dmg")
[ "$code" = 200 ] && echo "固定下载链接 OK" || { echo "固定下载链接返回 $code"; exit 1; }
