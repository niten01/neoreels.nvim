local retrieval = require("neoreels.retriever")
local M = {}

function M.new(opts, callbacks)
  local self = { entries = {}, seen = {}, index = 1, waiting = true, stopped = false, halted = false }
  local pump

  function self:stop()
    self.stopped = true
    if self.job then self.job:cancel(); self.job = nil end
  end

  function self:append(urls)
    local added = 0
    for _, url in ipairs(urls) do
      local normalized = retrieval.normalize(url)
      if normalized and not self.seen[normalized] and #self.entries < 500 then
        self.seen[normalized] = true
        self.entries[#self.entries + 1] = { url = normalized, status = "pending" }
        added = added + 1
      end
    end
    if self.finished and self.index < #self.entries and opts.auto_advance then
      self:next()
    else pump() end
    return added
  end

  function self:remaining()
    return math.max(0, #self.entries - self.index + 1)
  end

  function self:next()
    if self.stopped or self.index >= #self.entries then return false end
    self.index = self.index + 1
    self.waiting, self.halted, self.finished = true, false, false
    callbacks.wait()
    pump()
    return true
  end

  function self:retry()
    local entry = self.entries[self.index]
    if self.stopped or not entry then return false end
    local retry_current, found = entry.status == "failed", false
    for i = self.index, math.min(#self.entries, self.index + opts.prefetch) do
      if self.entries[i].status == "failed" then
        self.entries[i].status, found = "pending", true
      end
    end
    if not found then return false end
    self.halted = false
    if retry_current then
      self.waiting, self.finished = true, false
      callbacks.wait()
    end
    pump()
    return true
  end

  function self:ended(err)
    local entry = self.entries[self.index]
    if err and entry then entry.status = "failed"; callbacks.error(err) end
    self.finished = true
    if opts.auto_advance and not self.halted then self:next() end
    callbacks.change()
  end

  pump = function()
    if self.stopped or self.halted then callbacks.change(); return end
    local current = self.entries[self.index]
    if self.waiting and current then
      if current.status == "ready" then
        self.waiting = false
        if not callbacks.play(current.path, current.url) then
          current.status, self.halted = "failed", true
        end
      elseif current.status == "failed" then
        if not self:next() then self.halted = true end
        callbacks.change()
        return
      end
    end
    local protected = {}
    for i = self.index, math.min(#self.entries, self.index + opts.prefetch) do
      if self.entries[i].path then protected[self.entries[i].path] = true end
    end
    retrieval.trim(opts, protected)
    if not self.job then
      for i = self.index, math.min(#self.entries, self.index + opts.prefetch) do
        local entry = self.entries[i]
        if entry.status == "pending" then
          entry.status = "downloading"
          local job, err = retrieval.fetch(entry.url, opts, function(path, message, kind)
            if self.stopped then return end
            self.job = nil
            entry.status, entry.path = path and "ready" or "failed", path
            if message then
              callbacks.error(message)
              if kind == "auth" or kind == "rate" then self.halted = true end
            end
            pump()
          end, function(percent)
            if self.stopped then return end
            entry.progress = percent
            callbacks.change()
          end)
          self.job = job
          if not job then
            entry.status, self.halted = "failed", true
            callbacks.error(err)
          end
          break
        end
      end
    end
    callbacks.change()
  end
  return self
end

return M
