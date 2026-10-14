local M = {}
local uv = vim.uv or vim.loop

function M.start(opts, on_event)
  local self = { stopped = false, pending = false }
  local stdin, stdout, stderr = uv.new_pipe(false), uv.new_pipe(false), uv.new_pipe(false)
  local partial = ""
  local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
  end
  function self:stop()
    if self.stopped then return end
    self.stopped = true
    -- EOF lets the helper close its browser cleanly.
    if not stdin:is_closing() then stdin:shutdown(function() close(stdin) end) end
    if self.process and not self.exited then self.process:kill("sigterm") end
    close(stdout); close(stderr)
  end
  function self:request(count)
    if self.stopped or self.exited or self.pending then return end
    self.pending = true
    stdin:write(vim.json.encode({ count = count }) .. "\n")
  end
  local args = { opts.feed_script, "--browser", opts.browser, "--channel", opts.feed_channel }
  if not opts.feed_headless then args[#args + 1] = "--visible" end
  local function finished()
    if self.exited and self.eof and not self.reported and not self.stopped then
      self.reported = true
      vim.schedule(function() if not self.stopped then on_event({ type = "closed" }) end end)
    end
  end
  self.process = uv.spawn(opts.python, { args = args, stdio = { stdin, stdout, stderr } }, function()
    self.exited = true
    close(self.process); close(stdin)
    finished()
  end)
  if not self.process then self:stop(); close(stdin); return nil, "Unable to start the feed helper; run sh scripts/install-retrieval.sh" end
  stdout:read_start(function(err, data)
    if err or not data then self.eof = true; close(stdout); finished(); return end
    partial = partial .. data
    while true do
      local newline = partial:find("\n", 1, true)
      if not newline then break end
      local line = partial:sub(1, newline - 1)
      partial = partial:sub(newline + 1)
      local ok, event = pcall(vim.json.decode, line)
      if ok and type(event) == "table" then
        vim.schedule(function()
          if self.stopped then return end
          if event.type == "batch_end" or event.type == "error" then self.pending = false end
          on_event(event)
        end)
      end
    end
    if #partial > 65536 then self:stop(); vim.schedule(function() on_event({ type = "error", message = "Feed helper returned invalid data" }) end) end
  end)
  -- Never forward browser or cookie diagnostics into Neovim messages.
  stderr:read_start(function(err, data) if err or not data then close(stderr) end end)
  return self
end

return M
