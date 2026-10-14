local M = {}

-- Test-only media: generate a fixture and seed the normal retrieval cache.
function M.fixture()
  local base = vim.fn.tempname()
  vim.fn.mkdir(base, "p")
  local video = base .. "/fixture.mp4"
  local result = vim.fn.system({ "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
    "-f", "lavfi", "-i", "testsrc2=size=90x160:rate=12", "-t", "2", "-c:v", "libx264", video })
  assert(vim.v.shell_error == 0, result)
  local url = "https://www.instagram.com/reel/TestFixture/"
  local cached = base .. "/media-" .. vim.fn.sha256(url) .. ".mp4"
  assert((vim.uv or vim.loop).fs_copyfile(video, cached))
  return { base = base, url = url, video = video, cached = cached }
end

function M.start(fixture, opts)
  local reels = require("neoreels")
  reels.setup(vim.tbl_extend("force", { cache_dir = fixture.base, auto_advance = false }, opts or {}))
  return reels.enqueue(fixture.url)
end

return M
