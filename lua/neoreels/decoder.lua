local uv = vim.uv or vim.loop
local M = {}

local function close(handle)
  if handle and not handle:is_closing() then
    handle:close()
  end
end

-- Decode ahead into a bounded queue; a timer supplies frames at the requested FPS.
-- Pausing stops consuming the queue, so the pipe backpressures FFmpeg.
function M.start(path, opts, on_frame, on_exit)
  local self = {
    stdout = uv.new_pipe(false), stderr = uv.new_pipe(false), timer = uv.new_timer(),
    queue = {}, head = 1, tail = 0, partial = "", errors = "",
    paused = false, stopped = false, reading = false, eof = false, exited = false,
  }
  local pixel_format = opts.color and "rgb24" or "gray"
  local frame_size = opts.width * opts.height * (opts.color and 3 or 1)
  local function queued()
    return self.tail - self.head + 1
  end

  function self:stop()
    if self.stopped then return end
    self.stopped = true
    self.timer:stop()
    close(self.timer)
    close(self.stdout)
    close(self.stderr)
    if self.process and not self.exited then
      self.process:kill("sigterm")
    end
    self.queue, self.partial = {}, ""
  end

  local function finish(err)
    if self.stopped then return end
    self:stop()
    vim.schedule(function() on_exit(err) end)
  end

  local function read(err, chunk)
    if self.stopped then return end
    if err then
      finish("Unable to read FFmpeg output: " .. err)
      return
    end
    if not chunk then
      self.eof, self.reading = true, false
      close(self.stdout)
      return
    end
    local data = self.partial .. chunk
    local count = math.floor(#data / frame_size)
    for index = 1, count do
      self.tail = self.tail + 1
      self.queue[self.tail] = data:sub((index - 1) * frame_size + 1, index * frame_size)
    end
    self.partial = data:sub(count * frame_size + 1)
    if queued() >= opts.fps * 2 then
      self.stdout:read_stop()
      self.reading = false
    end
  end

  -- A terminal cell is about twice as tall as it is wide. Fit into a double-height
  -- pixel canvas first, then squash vertically to preserve the displayed aspect.
  local pixel_height = math.max(1, math.floor(opts.height / opts.cell_aspect + 0.5))
  local filter = string.format(
    "fps=%d,scale=%d:%d:force_original_aspect_ratio=decrease,pad=%d:%d:(ow-iw)/2:(oh-ih)/2:black,scale=%d:%d,format=%s",
    opts.fps, opts.width, pixel_height, opts.width, pixel_height, opts.width, opts.height, pixel_format
  )
  local args = { "-nostdin", "-hide_banner", "-loglevel", "error", "-filter_threads", "1" }
  vim.list_extend(args, {
    "-threads", "1", "-i", path, "-map", "0:v:0", "-an", "-sn", "-dn", "-vf", filter,
    "-threads", "1", "-f", "rawvideo", "-pix_fmt", pixel_format, "pipe:1",
  })
  local process, spawn_error = uv.spawn(opts.ffmpeg, {
    args = args, stdio = { nil, self.stdout, self.stderr },
  }, function(code, signal)
    self.exited, self.exit_code = true, code
    close(self.process)
    -- Drain stderr before reporting a decoder failure.
    if not self.stopped and code == 0 and signal ~= 0 then
      self.exit_code = signal
    end
  end)
  self.process = process
  if not process then
    self:stop()
    return nil, "Unable to start FFmpeg: " .. tostring(spawn_error)
  end
  self.stderr:read_start(function(err, chunk)
    if chunk then self.errors = (self.errors .. chunk):sub(-4096) end
    if err or not chunk then
      self.stderr_eof = true
      close(self.stderr)
    end
  end)
  self.stdout:read_start(read)
  self.reading = true
  self.timer:start(0, math.max(1, math.floor(1000 / opts.fps + 0.5)), function()
    if self.stopped then return end
    if self.exited and self.exit_code ~= 0 and self.stderr_eof then
      finish(self.errors ~= "" and vim.trim(self.errors) or "FFmpeg exited with code " .. self.exit_code)
      return
    end
    if not self.paused and queued() > 0 then
      local frame = self.queue[self.head]
      self.queue[self.head] = nil
      self.head = self.head + 1
      if queued() == 0 then self.queue, self.head, self.tail = {}, 1, 0 end
      -- Coalesce UI work if Neovim is busy; never accumulate scheduled renders.
      self.latest = frame
      if not self.render_pending then
        self.render_pending = true
        vim.schedule(function()
          self.render_pending = false
          if not self.stopped then on_frame(self.latest) end
        end)
      end
    end
    if not self.reading and not self.eof and queued() < opts.fps then
      self.stdout:read_start(read)
      self.reading = true
    end
    if self.exited and self.eof and queued() == 0 then
      -- Let the final scheduled render run before closing the decoder.
      vim.schedule(function()
        if self.stopped then return end
        if self.partial ~= "" then finish("FFmpeg returned an incomplete frame")
        elseif not self.latest then finish("Video contains no frames")
        else finish() end
      end)
    end
  end)
  return self
end

return M
