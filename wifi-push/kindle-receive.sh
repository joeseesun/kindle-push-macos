#!/bin/sh
# Dedicated SSH key: allow article transfer only, never arbitrary commands.
set -eu
umask 077
dest=/mnt/us/documents/我的文章
case "${SSH_ORIGINAL_COMMAND:-}" in
  ping) printf 'kindle-push-v2\n'; exit 0 ;;
  put|get) action=$SSH_ORIGINAL_COMMAND ;;
  *) echo 'Unsupported operation' >&2; exit 1 ;;
esac
IFS= read -r name
case "$name" in
  ''|.*|*/*|*\\*) echo 'Invalid filename' >&2; exit 1 ;;
  *.azw|*.azw3|*.cbr|*.cbt|*.cbz|*.chm|*.djv|*.djvu|*.doc|*.docm|*.epub|*.fb2|*.fb2.zip|*.fb3|*.gif|*.htm.zip|*.html.zip|*.htmlz|*.jpeg|*.jpg|*.md.zip|*.mobi|*.pdb|*.pdf|*.png|*.prc|*.rtf.zip|*.tcr|*.tif|*.tiff|*.txt.zip|*.webp|*.xps) ;;
  *) echo 'Unsupported file type' >&2; exit 1 ;;
esac
mkdir -p "$dest"
if [ "$action" = get ]; then
  cat "$dest/$name"
  exit
fi
IFS= read -r size
case "$size" in ''|*[!0-9]*) exit 1 ;; esac
[ "$size" -gt 0 ] && [ "$size" -le 104857600 ]
tmp="$dest/.receiving-$$"
trap 'rm -f "$tmp"' EXIT HUP INT TERM
# Read at most expected size plus one: reject oversized/incomplete streams.
head -c "$((size + 1))" > "$tmp"
actual=$(wc -c < "$tmp" | tr -d ' ')
[ "$actual" = "$size" ] || { echo 'Incomplete transfer' >&2; exit 1; }
mv -f "$tmp" "$dest/$name"
printf 'OK\n'
