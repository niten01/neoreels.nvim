vim.opt.runtimepath:prepend(vim.fn.getcwd())
vim.cmd("runtime plugin/neoreels.lua")
local reels = require("neoreels")
local api = vim.api
local ascii = require("neoreels.ascii")
local function check(value, message) assert(value, message) end
local function wait_for(predicate, message) check(vim.wait(4000, predicate, 10), message) end
local ns = api.nvim_create_namespace("neoreels.pixels")
local original_getmousepos = vim.fn.getmousepos
local helper = dofile("tests/helpers.lua")
local fixture = helper.fixture()
local function run()
  local lines, spans = ascii.render_rgb(string.char(255, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255), 4, 1, 4, 1, " @")
  check(lines[1] == "@@@@", "Saturated colors remain visible")
  check(#spans == 3 and spans[1].finish == 2, "Adjacent pixels merge into color spans")
  check(spans[1].color == 180 and spans[2].color == 30 and spans[3].color == 5, "RGB palette indexes")
  lines = ascii.render_rgb(string.rep(string.char(255, 0, 0), 4), 2, 2, 6, 2, " @")
  check(lines[1] == "  @@  " and lines[2] == "  @@  ", "Resize letterboxes instead of stretching")
  vim.o.lines, vim.o.columns = 70, 160
  check(helper.start(fixture, { reserve_space = false }), "Start cached fixture")
  wait_for(function() return (reels.status().frames or 0) >= 2 end, "Color frames render")
  local status = reels.status()
  check(status.width == 40 and status.height == 36, "Larger default size " .. vim.inspect(status))
  local marks = api.nvim_buf_get_extmarks(status.buffer, ns, 0, -1, { details = true })
  check(#marks > 0, "Color highlights applied")
  local groups = {}
  for _, mark in ipairs(marks) do groups[mark[4].hl_group] = true end
  check(vim.tbl_count(groups) > 5, "Video retains varied colors")
  check(api.nvim_get_hl(0, { name = "NeoReelsPixel180" }).fg == 0xff0000, "Red highlight color")
  reels.pause()
  vim.wait(100, function() return false end, 10)
  local paused = reels.status().frames
  vim.cmd("NeoReelsResize 60 50")
  local resized = reels.status()
  check(resized.width == 60 and resized.height == 50 and resized.buffer == status.buffer, "Resize preserves window and decoder")
  check(resized.frames == paused and resized.status == "paused", "Resize preserves playback position and pause")
  local content = api.nvim_buf_get_lines(status.buffer, 0, -1, false)
  check(#content == 50 and #content[1] == 60, "Resize redraws buffer immediately")
  check(not pcall(reels.resize, nil, 50), "Reject missing size")
  check(not pcall(reels.resize, 241, 50), "Reject excessive size")
  check(reels.status().width == 60, "Invalid resize leaves player intact")
  local editor = api.nvim_get_current_win()
  local mouse = { screenrow = 1, screencol = 1 }
  vim.fn.getmousepos = function() return mouse end
  local function mapping(key) return vim.fn.maparg(key, "n", false, true).callback end
  check(mapping("<LeftMouse>")() == "<LeftMouse>", "Ordinary clicks pass through")
  local geometry = api.nvim_win_get_config(status.window)
  mouse = { screenrow = geometry.row + 1, screencol = geometry.col + 1 }
  check(mapping("<LeftMouse>")() == "", "Free-corner press starts drag")
  mouse.screenrow, mouse.screencol = mouse.screenrow - 5, mouse.screencol - 10
  check(mapping("<LeftDrag>")() == "", "Resize drag consumed")
  wait_for(function() return reels.status().width == 70 and reels.status().height == 55 end, "Dragging expands the window")
  check(mapping("<LeftRelease>")() == "", "Resize release consumed")
  check(api.nvim_get_current_win() == editor and reels.status().frames == paused, "Dragging keeps editor focus and playback position")
  vim.fn.getmousepos = original_getmousepos
  reels.stop()
  check(next(vim.fn.maparg("<LeftMouse>", "n", false, true)) == nil, "Mouse mappings removed on stop")

  for _, corner in ipairs({ "top-left", "top-right", "bottom-left", "bottom-right" }) do
    helper.start(fixture, { corner = corner, width = 20, height = 18, reserve_space = false })
    local player = reels.status()
    local g = api.nvim_win_get_config(player.window)
    local right, bottom = corner:find("right") ~= nil, corner:find("bottom") ~= nil
    mouse = { screenrow = g.row + 1 + (bottom and 0 or g.height + 1),
      screencol = g.col + 1 + (right and 0 or g.width + 1) }
    vim.fn.getmousepos = function() return mouse end
    check(mapping("<LeftMouse>")() == "", "Handle works in " .. corner)
    mouse.screenrow = mouse.screenrow + (bottom and -3 or 3)
    mouse.screencol = mouse.screencol + (right and -4 or 4)
    mapping("<LeftDrag>")()
    wait_for(function() return reels.status().width == 24 and reels.status().height == 21 end, "Resize in " .. corner)
    mapping("<LeftRelease>")()
    reels.stop()
  end
  vim.fn.getmousepos = original_getmousepos
  vim.keymap.set("n", "<LeftMouse>", "<Nop>", { desc = "User mouse mapping" })
  helper.start(fixture, { color = false, width = 26, height = 23, reserve_space = false })
  wait_for(function() return (reels.status().frames or 0) >= 2 end, "Monochrome fallback renders")
  check(#api.nvim_buf_get_extmarks(reels.status().buffer, ns, 0, -1, {}) == 0, "Monochrome mode has no pixel highlights")
  check(vim.fn.maparg("<LeftMouse>", "n", false, true).desc == "User mouse mapping", "User mouse bindings preserved")
  reels.stop()
  check(vim.fn.maparg("<LeftMouse>", "n", false, true).desc == "User mouse mapping", "Stop retains user mouse mapping")
  vim.keymap.del("n", "<LeftMouse>")
  helper.start(fixture, { draggable = false })
  check(next(vim.fn.maparg("<LeftMouse>", "n", false, true)) == nil, "Drag can be disabled")
end
local ok, err = xpcall(run, debug.traceback)
vim.fn.getmousepos = original_getmousepos
reels.stop()
vim.fn.delete(fixture.base, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1")
else print("neoreels: color and resizing tests passed"); vim.cmd("qa!") end
