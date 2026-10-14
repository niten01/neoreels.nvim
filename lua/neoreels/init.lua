local M = {}
local api = vim.api
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":p:h:h:h")
local local_python = root .. "/.tools/venv/bin/python"
local local_ytdlp = root .. "/.tools/venv/bin/yt-dlp"
local defaults = {
  corner = "bottom-right", width = 40, height = 36, fps = 12,
  margin = 1, border = "rounded", ffmpeg = "ffmpeg",
  ramp = " .:-=+*#%@", cell_aspect = 0.5, color = true, draggable = true, reserve_space = true,
  browser = "firefox", prefetch = 2, auto_advance = true,
  ytdlp = vim.fn.executable(local_ytdlp) == 1 and local_ytdlp or "yt-dlp",
  cache_dir = vim.fn.stdpath("cache") .. "/neoreels", cache_max_files = 20,
  python = vim.fn.executable(local_python) == 1 and local_python or "python3",
  feed_script = root .. "/scripts/feed.py", feed_channel = "chrome", feed_headless = true,
}
local config = vim.deepcopy(defaults)
local state
local display_width, display_height
local pixel_namespace = api.nvim_create_namespace("neoreels.pixels")
local initialized = false
local reel_queue, feed_reader, feed_status
local open_video
local start_feed
local update_loading
local corners = { ["top-left"] = true, ["top-right"] = true, ["bottom-left"] = true, ["bottom-right"] = true }

local function notify(message)
  vim.notify("neoreels: " .. message, vim.log.levels.ERROR)
end

local function validate(opts)
  for name, limit in pairs({ width = 240, height = 120, fps = 60, margin = 100, prefetch = 5, cache_max_files = 1000 }) do
    local value = opts[name]
    local minimum = (name == "margin" or name == "prefetch") and 0 or 1
    assert(type(value) == "number" and value == math.floor(value) and value >= minimum and value <= limit,
      string.format("neoreels: %s must be an integer from %d to %d", name, minimum, limit))
  end
  assert(corners[opts.corner], "neoreels: invalid corner")
  assert(opts.border == "none" or opts.border == "rounded" or opts.border == "single" or opts.border == "double" or opts.border == "solid",
    "neoreels: border must be none, rounded, single, double, or solid")
  assert(type(opts.ramp) == "string" and #opts.ramp >= 2 and not opts.ramp:find("[^ -~]"),
    "neoreels: ramp must contain at least two printable ASCII characters")
  assert(type(opts.cell_aspect) == "number" and opts.cell_aspect >= 0.25 and opts.cell_aspect <= 1,
    "neoreels: cell_aspect must be between 0.25 and 1")
  assert(type(opts.ffmpeg) == "string" and opts.ffmpeg ~= "", "neoreels: ffmpeg must be an executable name or path")
  assert(opts.cache_max_files >= opts.prefetch + 1, "neoreels: cache_max_files must hold the current Reel and prefetched Reels")
  for _, name in ipairs({ "browser", "ytdlp", "cache_dir", "python", "feed_script", "feed_channel" }) do
    assert(type(opts[name]) == "string", "neoreels: " .. name .. " must be a string")
  end
  assert(opts.cache_dir ~= "" and opts.ytdlp ~= "" and opts.python ~= "", "neoreels: executable and cache paths must not be empty")
  assert(type(opts.auto_advance) == "boolean" and type(opts.feed_headless) == "boolean", "neoreels: auto_advance and feed_headless must be booleans")
  assert(type(opts.color) == "boolean" and type(opts.draggable) == "boolean", "neoreels: color and draggable must be booleans")
  assert(type(opts.reserve_space) == "boolean", "neoreels: reserve_space must be a boolean")
end

local function dock_width()
  local edge = config.border == "none" and 0 or 2
  local rows = math.max(1, vim.o.lines - vim.o.cmdheight - 2)
  local scale = math.min(1, math.max(1, rows - edge - config.margin * 2) / display_height)
  -- Leave useful editing space, even if the video is enlarged in a small UI.
  return math.max(5, math.min(math.ceil(display_width * scale) + edge + config.margin * 2, vim.o.columns - 21))
end

local function layout(dock)
  local edge = config.border == "none" and 0 or 2
  local rows = math.max(1, vim.o.lines - vim.o.cmdheight - 1)
  local columns = vim.o.columns
  local origin_row, origin_col = 0, 0
  dock = dock or (state and state.dock)
  if dock and api.nvim_win_is_valid(dock.win) then
    rows, columns = api.nvim_win_get_height(dock.win), api.nvim_win_get_width(dock.win)
    local pos = api.nvim_win_get_position(dock.win)
    origin_row, origin_col = pos[1], pos[2]
  end
  local margin = math.min(config.margin, math.max(0, math.floor((math.min(rows, columns) - edge - 1) / 2)))
  local scale = math.min(1, math.max(1, columns - edge - margin * 2) / display_width,
    math.max(1, rows - edge - margin * 2) / display_height)
  local width, height = math.max(1, math.floor(display_width * scale)), math.max(1, math.floor(display_height * scale))
  local bottom = config.corner:find("bottom", 1, true)
  local right = config.corner:find("right", 1, true)
  local geometry = {
    relative = "editor", style = "minimal", focusable = false, zindex = 45,
    width = width, height = height, border = config.border,
    row = origin_row + (bottom and math.max(0, rows - height - edge - margin) or margin),
    col = origin_col + (right and math.max(0, columns - width - edge - margin) or margin),
  }
  if config.border ~= "none" and width >= 12 then
    local arrows = { ["bottom-right"] = "↖", ["bottom-left"] = "↗", ["top-right"] = "↙", ["top-left"] = "↘" }
    geometry.title = config.draggable and " Reels " .. arrows[config.corner] .. " " or " Reels "
  end
  return geometry
end

local function render(s)
  if state ~= s or not api.nvim_buf_is_valid(s.buf) or not api.nvim_win_is_valid(s.win) then return end
  if not s.frame then require("neoreels.loading").render(s); return end
  local geometry = api.nvim_win_get_config(s.win)
  local ascii = require("neoreels.ascii")
  local renderer = config.color and ascii.render_rgb or ascii.render
  local lines, spans = renderer(s.frame, s.source_width, s.source_height, geometry.width, geometry.height, config.ramp)
  api.nvim_set_option_value("modifiable", true, { buf = s.buf })
  api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  api.nvim_set_option_value("modifiable", false, { buf = s.buf })
  api.nvim_buf_clear_namespace(s.buf, pixel_namespace, 0, -1)
  for _, span in ipairs(spans) do
    api.nvim_buf_set_extmark(s.buf, pixel_namespace, span.row, span.start, {
      end_col = span.finish, hl_group = "NeoReelsPixel" .. span.color, priority = 200,
    })
  end
end

local function stop_loading(s)
  if s.loading_timer then
    s.loading_timer:stop()
    if not s.loading_timer:is_closing() then s.loading_timer:close() end
    s.loading_timer = nil
  end
end

local function ensure_player()
  if state then return state end
  local buf = api.nvim_create_buf(false, true)
  api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  api.nvim_set_option_value("filetype", "neoreels", { buf = buf })
  api.nvim_set_option_value("modifiable", false, { buf = buf })
  local dock = config.reserve_space and require("neoreels.dock").open(config.corner, dock_width()) or nil
  local win = api.nvim_open_win(buf, false, layout(dock))
  local s = { buf = buf, win = win, status = "fetching", frames = 0, generation = 0,
    loading_started = (vim.uv or vim.loop).hrtime(), dock = dock }
  state = s
  api.nvim_set_option_value("winhighlight", "Normal:NeoReels,FloatBorder:NeoReelsBorder", { win = win })
  api.nvim_set_option_value("wrap", false, { win = win })
  api.nvim_set_option_value("winblend", 0, { win = win })
  if config.draggable and config.border ~= "none" then
    s.detach_mouse = require("neoreels.mouse").attach(function()
      if state ~= s or not api.nvim_win_is_valid(s.win) then return nil end
      return s, api.nvim_win_get_config(s.win), config.corner
    end, M.resize)
  end
  return s
end

local function show_loading(message, reset)
  local s = ensure_player()
  if reset then
    s.generation = s.generation + 1
    if s.decoder then s.decoder:stop(); s.decoder = nil end
    s.frame, s.progress, s.path, s.url, s.frames = nil, nil, nil, nil, 0
    s.status = "fetching"
    s.loading_started = (vim.uv or vim.loop).hrtime()
    api.nvim_buf_clear_namespace(s.buf, pixel_namespace, 0, -1)
  end
  if s.frame or s.status == "error" then return end
  s.message = message
  if not s.loading_timer then
    s.loading_timer = (vim.uv or vim.loop).new_timer()
    s.loading_timer:start(100, 100, vim.schedule_wrap(function()
      if state == s and not s.frame then render(s) end
    end))
  end
  render(s)
end

local function show_error(message)
  if state and not state.frame then
    state.status, state.message, state.progress = "error", message, nil
    api.nvim_buf_clear_namespace(state.buf, pixel_namespace, 0, -1)
    stop_loading(state)
    render(state)
  else notify(message) end
end

local function close_player()
  local old = state
  state = nil
  if not old then return end
  if old.detach_mouse then old.detach_mouse() end
  stop_loading(old)
  if old.decoder then old.decoder:stop() end
  if api.nvim_win_is_valid(old.win) then api.nvim_win_close(old.win, true) end
  if api.nvim_buf_is_valid(old.buf) then api.nvim_buf_delete(old.buf, { force = true }) end
  if old.dock then old.dock:close() end
end

function M.stop()
  if feed_reader then feed_reader:stop(); feed_reader = nil end
  if reel_queue then reel_queue:stop(); reel_queue = nil end
  feed_status = nil
  close_player()
end

local function resize()
  if not state then return end
  if not api.nvim_win_is_valid(state.win) then M.stop(); return end
  api.nvim_win_set_config(state.win, layout())
  render(state)
end

function M.resize(width, height)
  if not initialized then M.setup() end
  assert(type(width) == "number" and type(height) == "number", "neoreels: width and height must be numbers")
  local options = vim.tbl_extend("force", config, { width = width, height = height })
  validate(options)
  display_width, display_height = width, height
  if state and state.dock and api.nvim_win_is_valid(state.dock.win) then
    api.nvim_win_set_width(state.dock.win, dock_width())
  end
  resize()
  return true
end

function M.setup(opts)
  local next_config = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
  validate(next_config)
  M.stop()
  config = next_config
  display_width, display_height = config.width, config.height
  config.cache_dir = vim.fn.fnamemodify(vim.fn.expand(config.cache_dir), ":p"):gsub("/+$", "")
  initialized = true
  api.nvim_set_hl(0, "NeoReels", { fg = "#ffffff", bg = "#000000", ctermfg = 15, ctermbg = 0, default = true })
  api.nvim_set_hl(0, "NeoReelsBorder", { link = "FloatBorder", default = true })
  require("neoreels.ascii").setup_colors()
  local group = api.nvim_create_augroup("NeoReels", { clear = true })
  api.nvim_create_autocmd("ColorScheme", { group = group, callback = function()
    api.nvim_set_hl(0, "NeoReels", { fg = "#ffffff", bg = "#000000", ctermfg = 15, ctermbg = 0, default = true })
    api.nvim_set_hl(0, "NeoReelsBorder", { link = "FloatBorder", default = true })
    require("neoreels.ascii").setup_colors()
  end })
  api.nvim_create_autocmd("VimResized", { group = group, callback = function()
    if state and state.dock and api.nvim_win_is_valid(state.dock.win) then
      api.nvim_win_set_width(state.dock.win, dock_width())
    end
    resize()
  end })
  api.nvim_create_autocmd("WinResized", { group = group, callback = resize })
  api.nvim_create_autocmd({ "WinNew", "BufWinEnter" }, { group = group, callback = function()
    if state and state.dock then state.dock:wrap_editors() end
  end })
  api.nvim_create_autocmd("OptionSet", {
    group = group, pattern = { "cmdheight", "laststatus", "showtabline" }, callback = resize,
  })
  api.nvim_create_autocmd("WinClosed", { group = group, callback = function(event)
    if state and (tonumber(event.match) == state.win or (state.dock and tonumber(event.match) == state.dock.win)) then M.stop() end
  end })
  api.nvim_create_autocmd("BufWipeout", { group = group, callback = function(event)
    if state and (event.buf == state.buf or (state.dock and event.buf == state.dock.buf)) then M.stop() end
  end })
  api.nvim_create_autocmd("VimLeavePre", { group = group, callback = M.stop })
end

open_video = function(path, on_end)
  if vim.fn.filereadable(path) ~= 1 then
    show_error("The downloaded Reel is unavailable. Start again with :NeoReelsPlay.")
    return false
  end
  if vim.fn.executable(config.ffmpeg) ~= 1 then show_error("Install FFmpeg or set the ffmpeg option"); return false end
  show_loading("Preparing your Reel", true)
  local s = state
  s.path, s.status = path, "loading"
  local generation = s.generation
  -- Decode a larger canvas once, then resize the display without restarting or
  -- losing playback position. The extra samples preserve detail when enlarged.
  local scale = math.min(2, 240 / config.width, 120 / config.height)
  s.source_width = math.floor(config.width * scale)
  s.source_height = math.floor(config.height * scale)
  local decode_options = vim.tbl_extend("force", config, { width = s.source_width, height = s.source_height })
  local decoder, err = require("neoreels.decoder").start(path, decode_options, function(frame)
    if state ~= s or s.generation ~= generation then return end
    stop_loading(s)
    s.frame, s.frames = frame, s.frames + 1
    s.status = s.decoder.paused and "paused" or "playing"
    render(s)
  end, function(decode_error)
    if state ~= s or s.generation ~= generation then return end
    s.status = decode_error and "error" or "ended"
    if decode_error then s.frame = nil; show_error("Unable to play this Reel") end
    if on_end then on_end(decode_error and "Unable to play this Reel" or nil) end
  end)
  if not decoder then show_error(err); return false end
  s.decoder = decoder
  return true
end

local function request_feed()
  if not feed_reader or feed_status ~= "ready" or not reel_queue or reel_queue.halted then return end
  if #reel_queue.entries >= 500 then
    feed_status = "idle"
    vim.notify("neoreels: Queue limit reached. Restart :NeoReelsPlay to continue.")
    return
  end
  local wanted = config.prefetch + 1 - reel_queue:remaining()
  if wanted > 0 then feed_reader:request(wanted) end
end

update_loading = function()
  if not state or state.frame or state.status == "error" or state.status == "loading" then return end
  local entry = reel_queue and reel_queue.entries[reel_queue.index]
  if entry and entry.status == "downloading" then
    state.progress = entry.progress
    show_loading(reel_queue.index == 1 and "Downloading your first Reel" or "Downloading your next Reel")
  elseif feed_status == "starting" then show_loading("Connecting to Instagram")
  else show_loading("Finding your next Reel") end
end

local function create_queue()
  M.stop()
  show_loading("Finding your next Reel", true)
  local q
  q = require("neoreels.queue").new(config, {
    wait = function() show_loading("Fetching your next Reel", true) end,
    error = show_error,
    change = function() request_feed(); update_loading() end,
    play = function(path, url)
      local ok = open_video(path, function(err)
        if reel_queue == q then q:ended(err) end
      end)
      if ok then state.url = url end
      return ok
    end,
  })
  reel_queue = q
  return q
end

function M.enqueue(urls)
  if not initialized then M.setup() end
  if type(urls) == "string" then urls = { urls } end
  if type(urls) ~= "table" then notify("Provide a list of Reel URLs"); return false end
  local normalized = {}
  for _, url in ipairs(urls) do
    local value = require("neoreels.retriever").normalize(url)
    if not value then notify("Provide an HTTPS Instagram Reel or post URL"); return false end
    normalized[#normalized + 1] = value
  end
  if #normalized == 0 then return false end
  local q = reel_queue or create_queue()
  return q:append(normalized) > 0
end

function M.play(path)
  if not initialized then M.setup() end
  if path == nil then return start_feed() end
  if not require("neoreels.retriever").normalize(path) then notify("Provide an HTTPS Instagram Reel URL"); return false end
  create_queue()
  return M.enqueue(path)
end

start_feed = function()
  create_queue()
  feed_status = "starting"
  show_loading("Connecting to Instagram")
  if config.browser == "" then show_error("Set browser to your logged-in browser"); return false end
  if vim.fn.executable(config.ytdlp) ~= 1 or vim.fn.executable(config.python) ~= 1 then
    show_error("Run sh scripts/install-retrieval.sh before starting the feed"); return false
  end
  if vim.fn.executable(config.ffmpeg) ~= 1 then show_error("Install FFmpeg before starting the feed"); return false end
  local q = reel_queue
  local reader, err = require("neoreels.feed").start(config, function(event)
    if reel_queue ~= q then return end
    if event.type == "ready" then feed_status = "ready"; request_feed()
    elseif event.type == "reel" and event.url then M.enqueue(event.url)
    elseif event.type == "batch_end" then
      -- A zero-result batch must not trigger an endless retry loop.
      if event.count == 0 then feed_status = "idle" end
      request_feed()
    elseif event.type == "error" then
      feed_status = "error"
      show_error(event.message or "Personalized feed retrieval failed")
    elseif event.type == "closed" then
      if feed_status ~= "error" and state and not state.frame then show_error("Instagram feed closed. Check your browser login and start again with :NeoReelsPlay.") end
      if feed_status ~= "error" then feed_status = "closed" end
    end
    update_loading()
  end)
  if not reader then show_error(err); return false end
  feed_reader = reader
  update_loading()
  return true
end

function M.next()
  return reel_queue and reel_queue:next() or false
end

function M.retry()
  return reel_queue and reel_queue:retry() or false
end

function M.queue()
  if not reel_queue then return {} end
  local result = {}
  for i, entry in ipairs(reel_queue.entries) do
    result[i] = { url = entry.url, status = entry.status, current = i == reel_queue.index }
  end
  return result
end

function M.pause()
  if not state or not state.decoder or state.decoder.stopped then return false end
  state.decoder.paused = not state.decoder.paused
  state.status = state.decoder.paused and "paused" or "playing"
  return state.decoder.paused
end

function M.status()
  local result = state and { status = state.status, path = state.path, frames = state.frames, window = state.win, buffer = state.buf, url = state.url }
    or { status = reel_queue and (reel_queue.halted and "error" or "fetching") or "stopped" }
  if reel_queue then result.queue_index, result.queue_size = reel_queue.index, #reel_queue.entries end
  if state and api.nvim_win_is_valid(state.win) then
    local geometry = api.nvim_win_get_config(state.win)
    result.width, result.height, result.color = geometry.width, geometry.height, config.color
    result.dock = state.dock and state.dock.win or nil
  end
  result.feed = feed_status
  if state and not state.frame then result.message, result.progress = state.message, state.progress end
  return result
end

return M
