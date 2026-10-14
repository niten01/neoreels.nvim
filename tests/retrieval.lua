vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/neoreels.lua")
local api, uv = vim.api, vim.uv or vim.loop
local reels = require("neoreels")
local base = vim.fn.tempname()
vim.fn.mkdir(base, "p")
local notices = {}
vim.notify = function(message) notices[#notices + 1] = message end
local function check(condition, message) assert(condition, message) end
local function wait_for(predicate, message)
  check(vim.wait(6000, predicate, 10), message .. " " .. vim.inspect(reels.status()))
end
local function url(code) return "https://www.instagram.com/reel/" .. code .. "/" end
local opts = { ytdlp = base .. "/downloader", python = "python3", browser = "firefox:test-profile",
  cache_dir = base .. "/cache", prefetch = 2, cache_max_files = 3, auto_advance = false,
  feed_script = base .. "/feed.py" }

local function run()
  local result = vim.fn.system({ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "testsrc2=size=90x160:rate=12", "-t", "1.5", "-c:v", "libx264", base .. "/fixture.mp4" })
  check(vim.v.shell_error == 0, result)
  vim.env.NEOREELS_TEST_DIR = base
  vim.fn.writefile(vim.split([=[#!/usr/bin/env python3
import os, sys, pathlib, shutil, time
root = pathlib.Path(os.environ["NEOREELS_TEST_DIR"])
args = sys.argv[1:]
code = args[-1].strip("/").split("/")[-1]
assert args[args.index("--cookies-from-browser") + 1] == "firefox:test-profile"
with (root / "calls").open("a") as log:
    log.write(code + "\n")
if code.startswith("Auth") and not (root / (code + "-once")).exists():
    (root / (code + "-once")).touch()
    print("Login cookies failed: sessionid=FAKE_SECRET", file=sys.stderr)
    sys.exit(1)
if code == "Slow":
    time.sleep(20)
if code == "Failure":
    print("Unavailable video", file=sys.stderr)
    sys.exit(1)
time.sleep(0.1)
sys.stdout.write("neoreels-progress:25:")
sys.stdout.flush()
time.sleep(0.05)
print("100:NA", flush=True)
time.sleep(0.15)
print("neoreels-progress:100:100:NA", file=sys.stderr, flush=True)
target = args[args.index("--output") + 1].replace("%(ext)s", "mp4")
shutil.copyfile(root / "fixture.mp4", target)
print(target)
]=], "\n"), opts.ytdlp)
  uv.fs_chmod(opts.ytdlp, 493)
  vim.fn.writefile(vim.split([=[import sys, json
print(json.dumps({"type":"ready"}), flush=True)
index = 0
for line in sys.stdin:
    count = json.loads(line)["count"]
    for _ in range(count):
        index += 1
        print(json.dumps({"type":"reel", "url":"https://www.instagram.com/reel/Feed%d/" % index}), flush=True)
    print(json.dumps({"type":"batch_end", "count":count}), flush=True)
]=], "\n"), opts.feed_script)
  reels.setup(opts)
  check(not reels.enqueue("https://example.com/reel/Bad/"), "Reject foreign URLs")
  check(reels.enqueue({ url("One") .. "?igsh=tracking", url("Two"), url("Three"), url("Four") }), "Create queue")
  wait_for(function()
    local q = reels.queue()
    return reels.status().url == url("One") and q[2].status == "ready" and q[3].status == "ready"
  end, "Prefetch two clips ahead while first plays")
  check(reels.queue()[4].status == "pending", "Do not fetch beyond prefetch horizon")
  check(not reels.enqueue(url("One")), "Deduplicate normalized URL")
  check(reels.pause(), "Pause queued playback")
  local frame_count = reels.status().frames
  vim.wait(150, function() return false end, 10)
  check(reels.status().frames <= frame_count + 1, "Queue respects pause")
  check(reels.next(), "Skip to cached next clip")
  check(reels.status().url == url("Two"), "Cached next starts immediately")
  wait_for(function() return reels.queue()[4].status == "ready" end, "Refill prefetch horizon")
  check(#vim.fn.glob(opts.cache_dir .. "/media-*", false, true) <= 3, "Cache stays bounded")
  check(reels.next() and reels.status().url == url("Three"), "Third prefetched clip survives eviction")
  local before = #vim.fn.readfile(base .. "/calls")
  reels.stop()
  check(reels.play(url("Three")), "Replay cached URL")
  wait_for(function() return reels.status().url == url("Three") end, "Cache replay")
  check(#vim.fn.readfile(base .. "/calls") == before, "Cache hit avoids retrieval")
  reels.stop()

  reels.setup(vim.tbl_extend("force", opts, { auto_advance = true }))
  check(reels.enqueue({ url("AutoOne"), url("AutoTwo") }), "Queue automatic playback")
  wait_for(function() return reels.status().url == url("AutoTwo") end, "Automatically advance at EOF")
  wait_for(function() return reels.status().status == "ended" end, "Queue ends at last frame")
  check(reels.enqueue(url("AutoThree")), "Append after EOF")
  wait_for(function() return reels.status().url == url("AutoThree") end, "Late append resumes automatic playback")
  reels.stop()

  reels.setup(opts)
  check(reels.play(url("Auth")), "Start authentication failure")
  wait_for(function() return reels.status().status == "error" end, "Authentication failure halts queue")
  check(not table.concat(notices):find("FAKE_SECRET", 1, true), "Never expose cookie diagnostics")
  check(reels.retry(), "Retry after login is fixed")
  wait_for(function() return reels.status().url == url("Auth") end, "Retry plays clip")
  reels.stop()

  reels.setup(opts)
  check(reels.enqueue({ url("BeforeAuth"), url("AuthPrefetch") }), "Authentication failure during prefetch")
  wait_for(function() return reels.status().url == url("BeforeAuth") and reels.queue()[2].status == "failed" end, "Prefetch auth failure preserves current video")
  local previous_buffer = reels.status().buffer
  check(reels.retry(), "Retry failed prefetch")
  wait_for(function() return reels.queue()[2].status == "ready" end, "Retry downloads prefetched video")
  check(reels.status().buffer == previous_buffer, "Prefetch retry does not restart current playback")
  reels.stop()

  reels.setup(opts)
  check(reels.enqueue({ url("Failure"), url("GoodAfterFailure") }), "Queue failure followed by good clip")
  wait_for(function() return reels.status().url == url("GoodAfterFailure") end, "Skip unavailable Reel")
  reels.stop()
  check(reels.play(url("Slow")), "Start slow download")
  wait_for(function() return vim.tbl_contains(vim.fn.readfile(base .. "/calls"), "Slow") end, "Slow downloader started")
  reels.stop()
  wait_for(function() return #vim.fn.glob(opts.cache_dir .. "/.download-*", false, true) == 0 end, "Canceled downloads clean temporary files")
  check(reels.status().status == "stopped", "Canceled downloader cannot restart playback")

  reels.setup(opts)
  vim.cmd("NeoReelsPlay")
  local first = reels.status()
  check(first.status == "fetching" and api.nvim_win_is_valid(first.window), "Play immediately opens fetching window")
  check(first.message == "Connecting to Instagram" and table.concat(api.nvim_buf_get_lines(first.buffer, 0, -1, false)):find("Connecting", 1, true), "Connection progress is visible")
  wait_for(function() return reels.status().progress == 25 end, "Download percentage reaches player")
  check(table.concat(api.nvim_buf_get_lines(first.buffer, 0, -1, false)):find("25%%"), "Real percentage displayed inside player")
  wait_for(function() return reels.status().url == url("Feed1") and #reels.queue() == 3 end, "Feed discovery populates bounded prefetch queue")
  check(reels.status().window == first.window and reels.status().buffer == first.buffer, "Loading window becomes video window")
  wait_for(function() return (reels.status().frames or 0) >= 2 end, "First frames render")
  check(reels.next(), "Advance feed")
  wait_for(function() return #reels.queue() == 4 and reels.status().url == url("Feed2") end, "Feed discovery replenishes on demand")
  reels.stop()
  local rate_message, kind = require("neoreels.retriever").classify("HTTP Error 429: Too Many Requests")
  check(kind == "rate" and rate_message:find("rate limited", 1, true), "Report rate limits without leaking diagnostics")

  -- Errors written immediately before helper exit must not be dropped by the
  -- process-exit callback, or users would only see an unexplained closed feed.
  vim.fn.writefile({ "import json", "print(json.dumps({'type':'error','message':'Test login required'}), flush=True)" }, opts.feed_script)
  reels.setup(opts)
  check(reels.play(), "Start helper that reports an immediate login error")
  wait_for(function() return reels.status().feed == "error" end, "Helper error survives immediate exit")
  check(reels.status().message == "Test login required" and table.concat(api.nvim_buf_get_lines(reels.status().buffer, 0, -1, false)):find("required", 1, true), "Feed error stays inside player")
  reels.stop()
  reels.setup(vim.tbl_extend("force", opts, { ytdlp = "missing-neoreels-downloader" }))
  check(not reels.play(), "Missing downloader fails immediately")
  check(reels.status().status == "error" and api.nvim_win_is_valid(reels.status().window), "Dependency failure remains visible in player")
  reels.resize(10, 5)
  local error_lines = api.nvim_buf_get_lines(reels.status().buffer, 0, -1, false)
  check(#error_lines == 5 and #error_lines[1] == 10, "Loading/error screen fits a tiny resized player")
  reels.stop()
  vim.wait(300, function() return false end, 10)
  local live = 0
  uv.walk(function(handle) if handle:get_type() == "process" and not handle:is_closing() then live = live + 1 end end)
  check(live == 0, "Stop reaps downloader, decoder, and feed helper")
end

local ok, err = xpcall(run, debug.traceback)
reels.stop()
vim.wait(200, function() return false end, 10)
vim.fn.delete(base, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1")
else print("neoreels: retrieval and feed tests passed"); vim.cmd("qa!") end
