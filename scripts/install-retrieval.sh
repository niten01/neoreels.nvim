#!/usr/bin/env sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
python3 -m venv "$root/.tools/venv"
"$root/.tools/venv/bin/python" -m pip install --upgrade yt-dlp playwright
printf 'Retrieval installed. Feed browsing uses Google Chrome by default.\n'
printf 'For bundled Chromium: %s/.tools/venv/bin/python -m playwright install chromium\n' "$root"
