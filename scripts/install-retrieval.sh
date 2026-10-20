#!/usr/bin/env sh
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
python3 -m venv "$root/.tools/venv"
"$root/.tools/venv/bin/python" -m pip install --upgrade yt-dlp playwright
"$root/.tools/venv/bin/python" -m playwright install chromium
printf 'Retrieval installed, including bundled Chromium. The feed uses Chrome when available, otherwise Chromium.\n'
