vim.opt.runtimepath:prepend(vim.fn.getcwd())
local api = vim.api
local reels = require("neoreels")
local helper = dofile("tests/helpers.lua")
local fixture = helper.fixture()
local function check(condition, message) assert(condition, message) end
local function clear_of_editors(status)
  local video = api.nvim_win_get_config(status.window)
  for _, win in ipairs(api.nvim_tabpage_list_wins(0)) do
    if win ~= status.dock and api.nvim_win_get_config(win).relative == "" then
      local pos = api.nvim_win_get_position(win)
      local right = pos[2] + api.nvim_win_get_width(win)
      check(right <= video.col or pos[2] >= video.col + video.width + 2, "Video must not cover an editor window")
    end
  end
end
local function run()
  local editor = api.nvim_get_current_win()
  local width = api.nvim_win_get_width(editor)
  api.nvim_set_option_value("wrap", false, { win = editor })
  helper.start(fixture, { width = 18, height = 16 })
  local active = reels.status()
  check(active.dock and api.nvim_win_is_valid(active.dock), "Reserve a normal side column")
  check(api.nvim_get_current_win() == editor, "Keep editing focus")
  check(api.nvim_get_option_value("wrap", { win = editor }), "Wrap previously unwrapped editor")
  check(api.nvim_win_get_width(editor) < width, "Editor shrinks around video")
  clear_of_editors(active)
  reels.resize(24, 18)
  clear_of_editors(reels.status())
  api.nvim_win_close(active.window, true)
  check(reels.status().status == "stopped" and not api.nvim_win_is_valid(active.dock), "Closing video releases dock")
  check(api.nvim_win_get_width(editor) == width, "Restore full editor width")
  check(not api.nvim_get_option_value("wrap", { win = editor }), "Restore original nowrap")

  api.nvim_set_option_value("wrap", true, { win = editor })
  helper.start(fixture, { corner = "top-left", width = 15, height = 13 })
  clear_of_editors(reels.status())
  active = reels.status()
  api.nvim_win_close(active.dock, true)
  check(reels.status().status == "stopped" and not api.nvim_win_is_valid(active.window), "Closing side column stops video")
  check(api.nvim_get_option_value("wrap", { win = editor }), "Preserve pre-existing wrap")

  local second = api.nvim_open_win(api.nvim_get_current_buf(), false, { split = "below", win = 0 })
  api.nvim_set_option_value("wrap", false, { win = second })
  helper.start(fixture, { width = 15, height = 13 })
  clear_of_editors(reels.status())
  check(api.nvim_get_option_value("wrap", { win = second }), "Wrap all editor splits")
  local third = api.nvim_open_win(api.nvim_get_current_buf(), false, { split = "below", win = second })
  check(api.nvim_get_option_value("wrap", { win = third }), "New editor splits wrap")
  -- Respect a user's explicit option change while the player is open.
  api.nvim_set_option_value("wrap", false, { win = editor })
  reels.stop()
  check(not api.nvim_get_option_value("wrap", { win = editor }), "Preserve manual nowrap change")
  check(not api.nvim_get_option_value("wrap", { win = second }), "Restore each window separately")
  api.nvim_win_close(third, true)
  api.nvim_win_close(second, true)

  helper.start(fixture, { reserve_space = false })
  check(not reels.status().dock and api.nvim_win_get_width(editor) == width, "Optional floating mode retains width")
  check(not api.nvim_get_option_value("wrap", { win = editor }), "Floating mode leaves wrap unchanged")
  reels.stop()
end
local ok, err = xpcall(run, debug.traceback)
reels.stop()
vim.fn.delete(fixture.base, "rf")
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1")
else print("neoreels: reserved space and wrapping tests passed"); vim.cmd("qa!") end
