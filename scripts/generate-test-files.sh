#!/usr/bin/env bash
#
# Generates the fixed-size files served under /downloads for TR-143
# DownloadDiagnostics tests. Safe to re-run: existing files are skipped
# unless --force is given.
set -euo pipefail

DOWNLOADS_ROOT="${DOWNLOADS_ROOT:-/var/www/tr143-speedtest/downloads}"
SIZES_MB="${SIZES_MB:-1 10 50 100 200 500 1000}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    --root=*) DOWNLOADS_ROOT="${arg#--root=}" ;;
    --sizes=*) SIZES_MB="${arg#--sizes=}" ;;
    *)
      echo "Usage: $0 [--root=/path/to/downloads] [--sizes=\"1 10 100 1000\"] [--force]" >&2
      exit 1
      ;;
  esac
done

mkdir -p "$DOWNLOADS_ROOT"

for mb in $SIZES_MB; do
  file="$DOWNLOADS_ROOT/${mb}MB.file"
  if [[ -f "$file" && "$FORCE" -eq 0 ]]; then
    echo "skip  $file (already exists)"
    continue
  fi
  if command -v fallocate >/dev/null 2>&1; then
    fallocate -l "${mb}M" "$file"
  else
    dd if=/dev/zero of="$file" bs=1M count="$mb" status=none
  fi
  chmod 644 "$file"
  echo "wrote $file"
done
