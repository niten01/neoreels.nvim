local M = {}
local uv = vim.uv or vim.loop

function M.normalize(url)
  if type(url) ~= "string" then return nil end
  local host, path = url:match("^https://([^/]+)(/[^?#]*)")
  if host ~= "instagram.com" and host ~= "www.instagram.com" then return nil end
  local code = path:match("^/reel/([%w_-]+)/?$") or path:match("^/reels/([%w_-]+)/?$")
    or path:match("^/p/([%w_-]+)/?$")
  if not code then return nil end
  return "https://www.instagram.com/reel/" .. code .. "/"
end

function M.classify(stderr)
  local message = (stderr or ""):lower()
  if message:find("429", 1, true) or message:find("too many requests", 1, true) then
    return "Instagram rate limited retrieval. Wait before retrying.", "rate"
  end
  if message:find("cookie", 1, true) or message:find("log in", 1, true)
    or message:find("login", 1, true) or message:find("challenge", 1, true) then
    return "Instagram login is unavailable. Log into the configured browser, resolve any challenge there, then start again with :NeoReelsPlay.", "auth"
  end
  return "Reel retrieval failed. It may be unavailable, blocked, too large, or unsupported by this yt-dlp version.", "download"
end

local function cached(opts, key)
  for _, path in ipairs(vim.fn.glob(opts.cache_dir .. "/media-" .. key .. ".*", false, true)) do
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file" and stat.size > 0 and not path:match("%.part$") then
      uv.fs_utime(path, os.time(), os.time())
      return path
    end
  end
end

function M.trim(opts, protected)
  local files = {}
  for _, path in ipairs(vim.fn.glob(opts.cache_dir .. "/media-*", false, true)) do
    local stat = uv.fs_stat(path)
    if stat and stat.type == "file" then files[#files + 1] = { path = path, time = stat.mtime.sec } end
  end
  table.sort(files, function(a, b) return a.time < b.time end)
  local remaining = #files
  for _, file in ipairs(files) do
    if remaining <= opts.cache_max_files then break end
    if not protected[file.path] then
      if uv.fs_unlink(file.path) then remaining = remaining - 1 end
    end
  end
end

function M.fetch(url, opts, callback, on_progress)
  local normalized = M.normalize(url)
  if not normalized then return nil, "Provide an HTTPS Instagram Reel or post URL" end
  local key = vim.fn.sha256(normalized)
  local found = cached(opts, key)
  if found then
    local canceled = false
    vim.schedule(function() if not canceled then callback(found) end end)
    return { cancel = function() canceled = true end }
  end
  if vim.fn.executable(opts.ytdlp) ~= 1 then return nil, "Install yt-dlp or run sh scripts/install-retrieval.sh" end
  vim.fn.mkdir(opts.cache_dir, "p")
  local workdir, mkdir_error = uv.fs_mkdtemp(opts.cache_dir .. "/.download-XXXXXX")
  if not workdir then return nil, "Unable to create download directory: " .. tostring(mkdir_error) end
  local args = {
    opts.ytdlp, "--ignore-config", "--no-playlist", "--progress", "--newline", "--progress-delta", "0.2", "--no-warnings", "--quiet",
    "--progress-template", "download:neoreels-progress:%(progress.downloaded_bytes)s:%(progress.total_bytes)s:%(progress.total_bytes_estimate)s",
    "--no-continue", "--socket-timeout", "15", "--retries", "1", "--fragment-retries", "1",
    "--max-filesize", "50M", "--format", "bv[height<=480]/b[height<=480]/wv/w",
    "--print", "after_move:filepath", "--output", workdir .. "/video.%(ext)s",
  }
  if opts.browser and opts.browser ~= "" then vim.list_extend(args, { "--cookies-from-browser", opts.browser }) end
  vim.list_extend(args, { "--", normalized })
  local canceled, process = false, nil
  local stderr_tail, output_path = "", ""
  local buffers = { stdout = "", stderr = "" }
  local function consume(stream, chunk)
    if canceled then return end
    if not chunk then chunk = "\n" end
    if stream == "stderr" then stderr_tail = (stderr_tail .. chunk):sub(-4096) end
    local partial = buffers[stream] .. chunk
    while true do
      local newline = partial:find("\n", 1, true)
      if not newline then break end
      local line = partial:sub(1, newline - 1)
      partial = partial:sub(newline + 1)
      local downloaded, total, estimated = line:match("neoreels%-progress:([^:]+):([^:]+):([^\r]+)")
      downloaded, total = tonumber(downloaded), tonumber(total) or tonumber(estimated)
      if downloaded and total and total > 0 and on_progress then
        local percent = math.min(100, downloaded / total * 100)
        vim.schedule(function() if not canceled then on_progress(percent) end end)
      end
      if stream == "stdout" and line:sub(1, #workdir + 1) == workdir .. "/" then output_path = vim.trim(line) end
    end
    if #partial > 4096 then partial = partial:sub(-4096) end
    buffers[stream] = partial
  end
  local ok, err = pcall(function()
    process = vim.system(args, { text = true, timeout = 120000,
      stdout = function(_, chunk) consume("stdout", chunk) end,
      stderr = function(_, chunk) consume("stderr", chunk) end,
    }, function(result)
      vim.schedule(function()
        if canceled then vim.fn.delete(workdir, "rf"); return end
        local path = output_path
        local ext = path:match("%.([%w]+)$")
        local stat = uv.fs_stat(path)
        if result.code == 0 and ext and path:sub(1, #workdir + 1) == workdir .. "/"
          and stat and stat.type == "file" and stat.size > 0 and stat.size <= 50 * 1024 * 1024 then
          local destination = opts.cache_dir .. "/media-" .. key .. "." .. ext
          local renamed = uv.fs_rename(path, destination)
          vim.fn.delete(workdir, "rf")
          if renamed then callback(destination)
          else callback(nil, "Unable to save Reel in cache", "download") end
        else
          vim.fn.delete(workdir, "rf")
          local message, kind = M.classify(stderr_tail)
          callback(nil, message, kind)
        end
      end)
    end)
  end)
  if not ok then vim.fn.delete(workdir, "rf"); return nil, "Unable to start yt-dlp: " .. tostring(err) end
  return { cancel = function()
    if canceled then return end
    canceled = true
    if process then process:kill(15) end
  end }
end

return M
