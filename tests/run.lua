vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/neoreels.lua")
local api, uv = vim.api, vim.uv or vim.loop
local reels = require("neoreels")
local helper = dofile("tests/helpers.lua")
local fixture = helper.fixture()
local decoder
local function check(condition, message) assert(condition, message) end
local function wait_for(predicate, message) check(vim.wait(5000, predicate, 10), message) end

local function run()
  local ascii = require("neoreels.ascii")
  check(vim.deep_equal(ascii.render(string.char(0, 255, 128, 0), 2, 2, 2, 2, " .#"), { " #", ". " }), "Luminance rendering")
  for _, name in ipairs({ "Play", "Pause", "Next", "Stop", "Resize" }) do
    check(vim.fn.exists(":NeoReels" .. name) == 2, "Register " .. name)
  end
  for _, name in ipairs({ "Feed", "Toggle", "Add", "Queue", "Retry" }) do
    check(vim.fn.exists(":NeoReels" .. name) == 0, "Remove redundant " .. name .. " command")
  end
  check(not pcall(reels.setup, { fps = 0 }), "Reject invalid FPS")
  check(not pcall(reels.setup, { corner = "middle" }), "Reject invalid corner")
  check(not pcall(reels.setup, { ramp = "☃" }), "Reject non-ASCII ramp")
  check(not reels.play(fixture.video), "Public play no longer accepts local videos")
  local frames, ended, error = 0, false, nil
  decoder = assert(require("neoreels.decoder").start(fixture.video, {
    width = 12, height = 11, fps = 12, cell_aspect = 0.5, ffmpeg = "ffmpeg", color = false,
  }, function(frame) check(#frame == 132, "Frame byte size"); frames = frames + 1 end,
  function(err) ended, error = true, err end))
  wait_for(function() return frames >= 2 end, "Decoder streams frames")
  decoder.paused = true
  vim.wait(100, function() return false end, 10)
  local paused = frames
  vim.wait(200, function() return false end, 10)
  check(frames == paused, "Decoder pauses frame consumption")
  decoder.paused = false
  wait_for(function() return ended end, "Decoder reaches EOF")
  check(not error and frames == 24, "All frames decoded")

  vim.o.lines, vim.o.columns = 40, 100
  local editor = api.nvim_get_current_win()
  check(helper.start(fixture, { width = 26, height = 23, reserve_space = false }), "Start cached fixture")
  wait_for(function() return reels.status().frames >= 2 end, "Cached Reel renders")
  check(api.nvim_get_current_win() == editor, "Keep editor focus")
  local active = reels.status()
  check(api.nvim_win_get_config(active.window).focusable == false, "Player is not focusable")
  vim.o.lines, vim.o.columns = 16, 30
  api.nvim_exec_autocmds("VimResized", {})
  local g = api.nvim_win_get_config(active.window)
  check(g.height < 23 and g.col + g.width + 2 <= vim.o.columns, "Fit smaller editor " .. vim.inspect(g))
  wait_for(function() return reels.status().status == "ended" end, "Reel ends")
  check(api.nvim_win_is_valid(active.window), "Last frame remains visible")
  reels.stop()
  check(not api.nvim_win_is_valid(active.window) and not api.nvim_buf_is_valid(active.buffer), "Stop removes player")

  vim.o.lines, vim.o.columns = 60, 100
  for _, corner in ipairs({ "top-left", "top-right", "bottom-left", "bottom-right" }) do
    helper.start(fixture, { corner = corner, reserve_space = false })
    active = reels.status()
    g = api.nvim_win_get_config(active.window)
    check((corner:find("top") and g.row == 1) or (corner:find("bottom") and g.row > 1), "Vertical corner")
    check((corner:find("left") and g.col == 1) or (corner:find("right") and g.col > 1), "Horizontal corner")
    api.nvim_win_close(active.window, true)
    check(reels.status().status == "stopped", "External close cleans up")
  end
  helper.start(fixture)
  api.nvim_buf_delete(reels.status().buffer, { force = true })
  check(reels.status().status == "stopped", "Buffer wipe cleans up")
  for _ = 1, 5 do helper.start(fixture); reels.stop() end
  vim.wait(300, function() return false end, 10)
  local live = 0
  uv.walk(function(handle) if handle:get_type() == "process" and not handle:is_closing() then live = live + 1 end end)
  check(live == 0, "Stopped processes are reaped")
end

local ok, err = xpcall(run, debug.traceback)
if decoder then decoder:stop() end
reels.stop()
vim.fn.delete(fixture.base, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1")
else print("neoreels: core tests passed"); vim.cmd("qa!") end
