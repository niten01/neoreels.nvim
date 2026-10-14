-- Opt-in integration test: reads browser cookies and connects to Instagram.
vim.opt.runtimepath:prepend(vim.fn.getcwd())
local reels = require("neoreels")
reels.setup({ browser = "firefox", cache_dir = vim.fn.getcwd() .. "/.cache/reels", auto_advance = false })
local ok, err = xpcall(function()
  assert(reels.play(), "Unable to launch feed")
  local initial = reels.status()
  assert(initial.window and initial.status == "fetching", "Play must open the loading window immediately")
  local ready = vim.wait(90000, function()
    local q, status = reels.queue(), reels.status()
    if status.feed == "error" or status.status == "error" then return true end
    return (status.frames or 0) >= 3 and #q >= 3 and q[2].status == "ready" and q[3].status == "ready"
  end, 50)
  local q, status = reels.queue(), reels.status()
  assert(ready and #q >= 3 and q[2].status == "ready" and q[3].status == "ready" and (status.frames or 0) >= 3,
    "Live retrieval did not complete: " .. status.status .. ", feed=" .. tostring(status.feed) .. ", message=" .. tostring(status.message))
  print("Live test: personalized feed retrieved, ASCII frames rendered, next two Reels prefetched")
  assert(status.window == initial.window and status.buffer == initial.buffer, "Loading must reuse the same player window")
  assert(reels.next(), "Unable to advance")
  assert(reels.status().queue_index == 2 and reels.status().path, "Prefetched next Reel did not start")
  print("Live test: next prefetched Reel started immediately")
end, debug.traceback)
reels.stop()
vim.wait(1500, function() return false end, 20)
if not ok then io.stderr:write(err .. "\n"); vim.cmd("cquit 1") else vim.cmd("qa!") end
