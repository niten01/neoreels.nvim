# neoreels.nvim

Watch your personalized Instagram Reels feed as colored ASCII in a resizable
Neovim corner window while you keep editing.

`:NeoReelsPlay` opens the player immediately. It shows an animated indicator while
connecting to Instagram and finding a Reel, then a download percentage when the
file size is known. The same window becomes the video player when the first frame
is ready. The next two Reels are prefetched in the background.

## Setup

Requires Neovim 0.10+, FFmpeg, Python 3.11+ on Linux/macOS, and Google Chrome.
Install with lazy.nvim:

```lua
{
  "niten01/neoreels.nvim",
  build = "sh scripts/install-retrieval.sh",
  cmd = { "NeoReelsPlay", "NeoReelsPause", "NeoReelsNext", "NeoReelsStop", "NeoReelsResize", "NeoReelsWrap" },
  opts = {},
}
```

For packer.nvim, add this inside your `require("packer").startup(function(use)`
function:

```lua
use {
  "niten01/neoreels.nvim",
  run = "sh scripts/install-retrieval.sh",
  cmd = { "NeoReelsPlay", "NeoReelsPause", "NeoReelsNext", "NeoReelsStop", "NeoReelsResize", "NeoReelsWrap" },
  config = function()
    require("neoreels").setup({})
  end,
}
```

Run `:PackerSync` to install the plugin, its retrieval dependencies, and compile
the command loader. Restart Neovim afterward.

Log into Instagram in Firefox, then run `:NeoReelsPlay`.

For a standalone checkout:

```sh
git clone https://github.com/niten01/neoreels.nvim.git
cd neoreels.nvim
sh scripts/install-retrieval.sh
nvim --cmd 'set runtimepath+=.' -c 'runtime plugin/neoreels.lua' -c NeoReelsPlay
```

## Controls

| Command | Action |
| --- | --- |
| `:NeoReelsPlay` | Start or restart your personalized feed |
| `:NeoReelsPause` | Pause / resume |
| `:NeoReelsNext` | Skip to the next Reel |
| `:NeoReelsStop` | Close the player and stop retrieval |
| `:NeoReelsResize 60 50` | Resize to 60 columns × 50 lines |
| `:NeoReelsWrap` | Toggle wrapped side-column mode / floating overlay |

The default window is 40 columns × 36 lines and fits smaller editors. Reels
reserves a side column so it never covers buffer text. Editor lines wrap at the
column's edge; stopping playback releases the space and restores previous wrap
settings. Neovim wraps inside rectangular windows, so the reserved column spans
the editor's full height, including the space above or below the video.

Run `:NeoReelsWrap` to switch modes during playback without restarting the video
or changing pause state. Disabling wrap mode restores the editor's full width and
previous wrap settings. The selected mode persists across Reels and subsequent
playback sessions until `setup()` resets it. Set `reserve_space = false` to start
in overlay mode by default.

Drag the free corner indicated by its title arrow: the top-left corner for bottom-right
placement. Enable mouse input with `:set mouse=a` if necessary. Existing mouse
mappings are preserved; dragging is disabled in modes with conflicting bindings.
Resizing keeps playback position, editor focus, and the screen-corner anchor.
Video proportions are preserved with letterboxing.

```lua
vim.keymap.set("n", "<leader>rp", "<cmd>NeoReelsPlay<cr>")
vim.keymap.set("n", "<leader>rn", "<cmd>NeoReelsNext<cr>")
vim.keymap.set("n", "<leader>rs", "<cmd>NeoReelsStop<cr>")
vim.keymap.set("n", "<leader>rw", "<cmd>NeoReelsWrap<cr>")
```

## Configuration

```lua
require("neoreels").setup({
  browser = "firefox",      -- browser[:profile][::container], e.g. firefox:profile-name
  corner = "bottom-right",  -- top-left, top-right, bottom-left, bottom-right
  width = 40, height = 36,   -- columns / lines, maxima 240 / 120
  fps = 12,                 -- 1–60
  color = true,             -- false for grayscale
  draggable = true,
  reserve_space = true,      -- wrap buffer text beside Reels; false for an overlay
  margin = 1,
  border = "rounded",       -- none, rounded, single, double, solid
  cell_aspect = 0.5,         -- terminal character width / height
  ramp = " .:-=+*#%@",       -- printable ASCII, dark to light
  prefetch = 2,              -- 0–5 upcoming clips
  auto_advance = true,
  cache_max_files = 20,      -- at least prefetch + 1
  -- cache_dir = vim.fn.stdpath("cache") .. "/neoreels",
  ffmpeg = "ffmpeg",
  -- ytdlp = "/path/to/yt-dlp", -- .tools/venv/bin/yt-dlp is auto-detected
  -- python = "/path/to/python", -- .tools/venv/bin/python is auto-detected
  feed_channel = "chrome",
  feed_headless = true,      -- false to see the feed helper browser
})
```

The helper imports Firefox's Instagram cookies into an isolated browser and
observes the web feed's responses and visible links. Cookie values stay in memory
and are never exported or shown in notifications. Its browsing and scrolling can
affect your Instagram recommendations and views. It does not like, follow,
comment, or send messages. Feed discovery depends on Instagram's changing web
interface.

Downloads run one at a time, with a 50 MiB limit per clip. Older inactive cached
videos are evicted to keep the cache within its file limit. Stopping cancels
downloads and closes the browser; cached videos remain for reuse. Login and
retrieval errors appear inside the loading player. Resolve login challenges in
Firefox, then run `:NeoReelsPlay` again.

To use Playwright's bundled Chromium instead of Google Chrome:

```sh
.tools/venv/bin/python -m playwright install chromium
```

Set `feed_channel = ""` afterward. Colors use a fixed 216-color foreground palette
with a 256-color terminal fallback. The `NeoReels` highlight group controls the
black video background; `NeoReelsBorder` controls the border.

The Lua API exposes `setup()`, `play()`, `pause()`, `next()`, `stop()`, `resize(w,h)`, `toggle_wrap()`,
and `status()`. Status includes the stage/message/progress while fetching and the
current video, frame count, window dimensions, and feed/queue position afterward.
Calling `setup()` stops playback and resets configuration and display size.

## Tests

Tests generate their own portrait fixtures; no demo video is bundled.

```sh
nvim --headless -u NONE -i NONE -l tests/run.lua
nvim --headless -u NONE -i NONE -l tests/retrieval.lua
nvim --headless -u NONE -i NONE -l tests/display.lua
nvim --headless -u NONE -i NONE -l tests/dock.lua
python3 -m unittest discover -s tests -p 'test_*.py'
```

`python3 tests/ui.py` tests actual Neovim mouse events (requires Python msgpack).
An opt-in integration test uses Firefox cookies, connects to Instagram, and
downloads real clips into `.cache/reels`:

```sh
nvim --headless -u NONE -i NONE -l tests/live.lua
```
